package io.github.monadboxlab.clashpseudo.vpn.network

import android.net.DnsResolver
import android.os.Build
import android.os.CancellationSignal
import android.os.SystemClock
import android.util.Base64
import androidx.annotation.Keep
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.nativecore.CoreErrors
import io.github.monadboxlab.clashpseudo.nativecore.CoreTransportException
import org.json.JSONArray
import org.json.JSONObject
import java.net.Inet4Address
import java.net.Inet6Address
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicBoolean

/** 系统 DNS 只使用装载时捕获的 Network，不改写用户的 nameserver。 */
internal class AndroidSystemDns(private val snapshot: UnderlyingSnapshot, private val executor: Executor) {
    private class Query(val cancellation: CancellationSignal? = null) {
        val cancelled = AtomicBoolean(false)
        val finished = CountDownLatch(1)
        @Volatile var answer: ByteArray? = null
        @Volatile var rcode: Int? = null
        @Volatile var error: Throwable? = null
        @Volatile var exited = false
        @Volatile var submitted = false
    }
    private val pending = ConcurrentHashMap<Long, Query>()
    private val closed = AtomicBoolean(false)
    private val registration = Object()
    private var invocations = 0
    val idle: Boolean get() = synchronized(registration) { invocations == 0 && pending.isEmpty() }
    fun awaitIdle(deadline: Long) {
        var interrupted = false
        try {
            synchronized(registration) {
                while (invocations != 0 || pending.isNotEmpty()) {
                    val left = deadline - SystemClock.elapsedRealtime()
                    if (left <= 0) return
                    try { registration.wait(left) } catch (_: InterruptedException) { interrupted = true }
                }
            }
        } finally { if (interrupted) Thread.currentThread().interrupt() }
    }
    private fun completed(requestId: Long, query: Query) = synchronized(registration) {
        pending.remove(requestId, query)
        registration.notifyAll()
    }
    private fun returned(requestId: Long, query: Query) = synchronized(registration) {
        if (query.exited) pending.remove(requestId, query)
        invocations--
        registration.notifyAll()
    }
    private val cancelledBeforeRegistration = mutableSetOf<Long>()
    private var registeredThrough = 0L
    private val registeredOutOfOrder = mutableSetOf<Long>()

    private fun register(requestId: Long, query: Query): Boolean = synchronized(registration) {
        require(requestId > 0) { "系统 DNS queryId 必须为正数" }
        if (closed.get()) return@synchronized false
        check(requestId > registeredThrough && registeredOutOfOrder.add(requestId)) { "系统 DNS 请求标识重复" }
        while (registeredThrough < Long.MAX_VALUE && registeredOutOfOrder.remove(registeredThrough + 1)) registeredThrough++
        check(pending.putIfAbsent(requestId, query) == null) { "系统 DNS 请求标识重复" }
        if (cancelledBeforeRegistration.remove(requestId)) query.cancelled.set(true)
        invocations++
        true
    }

    fun raw(requestId: Long, wire: ByteArray): ByteArray {
        val query = Query(CancellationSignal())
        if (!register(requestId, query)) return failure(
            CoreTransportException(Contract.CORE_ERROR_CANCELLED, "系统 DNS 所属内核已停止"), true, true)
        try {
            if (wire.size > Contract.DNS_REQUEST_BYTES) throw CoreTransportException(
                Contract.CORE_ERROR_INPUT_TOO_LARGE, "系统 DNS 请求超过 ${Contract.DNS_REQUEST_BYTES} 字节")
            if (Build.VERSION.SDK_INT < 29) throw CoreTransportException(
                Contract.CORE_ERROR_CAPABILITY_UNAVAILABLE, "Android ${Build.VERSION.SDK_INT} 没有公开的原始 DNS 消息查询接口")
            val network = snapshot.network ?: throw CoreTransportException(
                Contract.CORE_ERROR_CAPABILITY_UNAVAILABLE, "装载时没有可用的底层系统网络")
            if (query.cancelled.get()) { query.exited = true; return failure(CoreTransportException(Contract.CORE_ERROR_CANCELLED, "系统 DNS 请求在执行前取消"), true, true) }
            if (closed.get()) throw CoreTransportException(Contract.CORE_ERROR_CANCELLED, "系统 DNS 所属内核已停止")
            DnsResolver.getInstance().rawQuery(network, wire, DnsResolver.FLAG_EMPTY, executor, query.cancellation,
                object : DnsResolver.Callback<ByteArray> {
                    override fun onAnswer(answer: ByteArray, rcode: Int) {
                        query.answer = answer
                        query.rcode = rcode
                        query.exited = true
                        query.finished.countDown()
                        completed(requestId, query)
                    }
                    override fun onError(error: DnsResolver.DnsException) {
                        query.error = error
                        query.exited = true
                        query.finished.countDown()
                        completed(requestId, query)
                    }
                })
            query.submitted = true
            query.finished.await()
            val answer = query.answer
            if (answer != null && answer.size > Contract.DNS_RESULT_BYTES) throw CoreTransportException(
                Contract.CORE_ERROR_RESULT_TOO_LARGE, "系统 DNS 响应超过 ${Contract.DNS_RESULT_BYTES} 字节")
            return JSONObject().put("wire", answer?.let { Base64.encodeToString(it, Base64.NO_WRAP) } ?: JSONObject.NULL)
                .put("rcode", query.rcode ?: JSONObject.NULL).put("error", query.error?.let { error ->
                    CoreErrors.json(error).apply { if (error is DnsResolver.DnsException) put("platformCode", error.code) }
                } ?: JSONObject.NULL).put("cancelled", query.cancelled.get()).put("exited", query.exited)
                .toString().toByteArray(Charsets.UTF_8)
        } catch (error: Throwable) {
            if (!query.submitted) query.exited = true
            return failure(error, query.cancelled.get(), query.exited)
        } finally { returned(requestId, query) }
    }

    fun lookup(requestId: Long, host: String, family: Int): ByteArray {
        val query = Query()
        if (!register(requestId, query)) return failure(
            CoreTransportException(Contract.CORE_ERROR_CANCELLED, "系统 DNS 所属内核已停止"), true, true)
        return try {
            require(host.toByteArray(Charsets.UTF_8).size <= Contract.DNS_NAME_BYTES && family in setOf(0, 4, 6)) {
                "系统主机查询参数无效"
            }
            if (query.cancelled.get()) { query.exited = true; return failure(CoreTransportException(Contract.CORE_ERROR_CANCELLED, "系统主机查询在执行前取消"), true, true) }
            if (closed.get()) throw CoreTransportException(Contract.CORE_ERROR_CANCELLED, "系统 DNS 所属内核已停止")
            val network = snapshot.network ?: throw CoreTransportException(Contract.CORE_ERROR_CAPABILITY_UNAVAILABLE,
                "装载时没有可用的底层系统网络")
            val addresses = network.getAllByName(host).filter { family == 0 ||
                family == 4 && it is Inet4Address || family == 6 && it is Inet6Address }.mapNotNull { it.hostAddress }
            query.exited = true
            JSONObject().put("addresses", JSONArray(addresses)).put("error", JSONObject.NULL)
                .put("cancelled", query.cancelled.get()).put("exited", true).toString().toByteArray(Charsets.UTF_8)
        } catch (error: Throwable) {
            query.exited = true
            failure(error, query.cancelled.get(), true)
        } finally { returned(requestId, query) }
    }

    fun cancel(requestId: Long): ByteArray = cancel(requestId, false)

    private fun cancel(requestId: Long, allowClosed: Boolean): ByteArray {
        synchronized(registration) {
            if (closed.get() && !allowClosed) return JSONObject()
                .put("cancelled", true).put("exited", pending.isEmpty()).put("error", JSONObject.NULL)
                .toString().toByteArray(Charsets.UTF_8)
            invocations++
        }
        try { return cancelRegistered(requestId) }
        finally { synchronized(registration) { invocations--; registration.notifyAll() } }
    }

    private fun cancelRegistered(requestId: Long): ByteArray {
        var beforeRegistration = false
        val queries = synchronized(registration) {
            val selected = if (requestId == 0L) pending.values.toList() else listOfNotNull(pending[requestId])
            if (requestId > registeredThrough && requestId !in registeredOutOfOrder && selected.isEmpty()) {
                cancelledBeforeRegistration.add(requestId)
                beforeRegistration = true
            }
            selected
        }
        var error: Throwable? = null
        queries.forEach { query ->
            if (query.cancelled.compareAndSet(false, true)) {
                try { query.cancellation?.cancel() } catch (failure: Throwable) {
                    if (error == null) error = failure else if (error !== failure) error!!.addSuppressed(failure)
                }
                // 原始调用继续等待系统实际 callback；取消回执不释放其执行槽。
            }
        }
        return JSONObject().put("cancelled", beforeRegistration || queries.isNotEmpty()).put("exited", !beforeRegistration && queries.all { it.exited })
            .put("error", error?.let { CoreErrors.json(it) } ?: JSONObject.NULL).toString().toByteArray(Charsets.UTF_8)
    }

    fun close(): ByteArray {
        synchronized(registration) { closed.set(true) }
        return cancel(0, true)
    }

    private fun failure(error: Throwable, cancelled: Boolean = false, exited: Boolean = true): ByteArray =
        JSONObject().put("error", CoreErrors.json(error)).put("cancelled", cancelled).put("exited", exited)
            .toString().toByteArray(Charsets.UTF_8)
}

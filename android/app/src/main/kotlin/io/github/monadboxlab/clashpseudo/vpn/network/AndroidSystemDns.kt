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

/** System DNS uses only the Network captured during preparation and does not rewrite the user's nameserver. */
internal class AndroidSystemDns(
    private val snapshot: UnderlyingSnapshot,
    private val executor: Executor,
    private val rawQuery: (android.net.Network, ByteArray, Executor, CancellationSignal, DnsResolver.Callback<ByteArray>) -> Unit =
        { network, wire, callbacks, cancellation, callback ->
            DnsResolver.getInstance().rawQuery(network, wire, DnsResolver.FLAG_EMPTY, callbacks, cancellation, callback)
        },
) {
    private class Query(val cancellation: CancellationSignal? = null) {
        val cancelled = AtomicBoolean(false)
        val finished = CountDownLatch(1)
        @Volatile var answer: ByteArray? = null
        @Volatile var rcode: Int? = null
        @Volatile var error: Throwable? = null
        @Volatile var exited = false
        @Volatile var submitted = false
        var returned = false
    }
    private val pending = ConcurrentHashMap<Long, Query>()
    private val closed = AtomicBoolean(false)
    private val registration = Object()
    private var invocations = 0
    private var callbackRunnables = 0
    val idle: Boolean get() = synchronized(registration) { invocations == 0 && callbackRunnables == 0 && pending.isEmpty() }
    fun awaitIdle(deadline: Long) {
        var interrupted = false
        try {
            synchronized(registration) {
                while (invocations != 0 || callbackRunnables != 0 || pending.isNotEmpty()) {
                    val left = deadline - SystemClock.elapsedRealtime()
                    if (left <= 0) return
                    try { registration.wait(left) } catch (_: InterruptedException) { interrupted = true }
                }
            }
        } finally { if (interrupted) Thread.currentThread().interrupt() }
    }
    private fun settle(query: Query, answer: ByteArray? = null, rcode: Int? = null, error: Throwable? = null) = synchronized(query) {
        if (!query.exited) {
            if (!query.cancelled.get()) { query.answer = answer; query.rcode = rcode; query.error = error }
            query.exited = true
            query.finished.countDown()
            synchronized(registration) {
                if (query.returned) pending.entries.removeAll { it.value === query }
                registration.notifyAll()
            }
        }
    }

    // Android may enqueue a runnable which observes cancellation and never invokes Callback.
    private val callbacks = Executor { command ->
        synchronized(registration) { callbackRunnables++ }
        val released = AtomicBoolean(false)
        fun release() {
            if (released.compareAndSet(false, true)) synchronized(registration) {
                callbackRunnables--
                registration.notifyAll()
            }
        }
        try { executor.execute { try { command.run() } finally { release() } } }
        catch (error: Throwable) { release(); throw error }
    }
    private fun returned(requestId: Long, query: Query) = synchronized(registration) {
        query.returned = true
        if (query.exited) pending.remove(requestId, query)
        invocations--
        registration.notifyAll()
    }
    private val cancelledBeforeRegistration = mutableSetOf<Long>()
    private var registeredThrough = 0L
    private val registeredOutOfOrder = mutableSetOf<Long>()

    private fun register(requestId: Long, query: Query): Boolean = synchronized(registration) {
        require(requestId > 0) { "System DNS queryId must be positive" }
        if (closed.get()) return@synchronized false
        check(requestId > registeredThrough && registeredOutOfOrder.add(requestId)) { "Duplicate system DNS request identity" }
        while (registeredThrough < Long.MAX_VALUE && registeredOutOfOrder.remove(registeredThrough + 1)) registeredThrough++
        check(pending.putIfAbsent(requestId, query) == null) { "Duplicate system DNS request identity" }
        if (cancelledBeforeRegistration.remove(requestId)) query.cancelled.set(true)
        invocations++
        true
    }

    fun raw(requestId: Long, wire: ByteArray): ByteArray {
        val query = Query(CancellationSignal())
        if (!register(requestId, query)) return failure(
            CoreTransportException(Contract.CORE_ERROR_CANCELLED, "The core owning system DNS has stopped"), true, true)
        try {
            if (wire.size > Contract.DNS_REQUEST_BYTES) throw CoreTransportException(
                Contract.CORE_ERROR_INPUT_TOO_LARGE, "System DNS request exceeds ${Contract.DNS_REQUEST_BYTES} bytes")
            if (Build.VERSION.SDK_INT < 29) throw CoreTransportException(
                Contract.CORE_ERROR_CAPABILITY_UNAVAILABLE, "Android ${Build.VERSION.SDK_INT} has no public raw DNS query interface")
            val network = snapshot.network ?: throw CoreTransportException(
                Contract.CORE_ERROR_CAPABILITY_UNAVAILABLE, "No underlying system network was available during preparation")
            if (query.cancelled.get()) { query.exited = true; return failure(CoreTransportException(Contract.CORE_ERROR_CANCELLED, "System DNS request was cancelled before execution"), true, true) }
            if (closed.get()) throw CoreTransportException(Contract.CORE_ERROR_CANCELLED, "The core owning system DNS has stopped")
            rawQuery(network, wire, callbacks, checkNotNull(query.cancellation),
                object : DnsResolver.Callback<ByteArray> {
                    override fun onAnswer(answer: ByteArray, rcode: Int) { settle(query, answer, rcode) }
                    override fun onError(error: DnsResolver.DnsException) { settle(query, error = error) }
                })
            query.submitted = true
            query.finished.await()
            val answer = query.answer
            if (answer != null && answer.size > Contract.DNS_RESULT_BYTES) throw CoreTransportException(
                Contract.CORE_ERROR_RESULT_TOO_LARGE, "System DNS response exceeds ${Contract.DNS_RESULT_BYTES} bytes")
            return JSONObject().put("wire", answer?.let { Base64.encodeToString(it, Base64.NO_WRAP) } ?: JSONObject.NULL)
                .put("rcode", query.rcode ?: JSONObject.NULL).put("error", query.error?.let { error ->
                    CoreErrors.json(error).apply { if (error is DnsResolver.DnsException) put("platformCode", error.code) }
                } ?: JSONObject.NULL).put("cancelled", query.cancelled.get()).put("exited", query.exited)
                .toString().toByteArray(Charsets.UTF_8)
        } catch (error: Throwable) {
            if (!query.submitted) settle(query, error = error)
            else if (!query.exited) {
                query.cancelled.set(true)
                try { query.cancellation?.cancel(); settle(query) }
                catch (cancel: Throwable) { if (cancel !== error) error.addSuppressed(cancel) }
            }
            return failure(error, query.cancelled.get(), query.exited)
        } finally { returned(requestId, query) }
    }

    fun lookup(requestId: Long, host: String, family: Int): ByteArray {
        val query = Query()
        if (!register(requestId, query)) return failure(
            CoreTransportException(Contract.CORE_ERROR_CANCELLED, "The core owning system DNS has stopped"), true, true)
        return try {
            require(host.toByteArray(Charsets.UTF_8).size <= Contract.DNS_NAME_BYTES && family in setOf(0, 4, 6)) {
                "Invalid system host lookup arguments"
            }
            if (query.cancelled.get()) { query.exited = true; return failure(CoreTransportException(Contract.CORE_ERROR_CANCELLED, "System host lookup was cancelled before execution"), true, true) }
            if (closed.get()) throw CoreTransportException(Contract.CORE_ERROR_CANCELLED, "The core owning system DNS has stopped")
            val network = snapshot.network ?: throw CoreTransportException(Contract.CORE_ERROR_CAPABILITY_UNAVAILABLE,
                "No underlying system network was available during preparation")
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
                .put("cancelled", true).put("exited", invocations == 0 && callbackRunnables == 0 && pending.isEmpty()).put("error", JSONObject.NULL)
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
                try {
                    query.cancellation?.let { cancellation ->
                        cancellation.cancel()
                        // CancellationSignal may return without any Callback; invocation and executor drain remain separate.
                        settle(query)
                    }
                } catch (failure: Throwable) {
                    if (error == null) error = failure else if (error !== failure) error!!.addSuppressed(failure)
                }
            }
        }
        val exited = synchronized(registration) { !beforeRegistration && callbackRunnables == 0 && queries.all { it.exited && it.returned } }
        return JSONObject().put("cancelled", beforeRegistration || queries.isNotEmpty()).put("exited", exited)
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

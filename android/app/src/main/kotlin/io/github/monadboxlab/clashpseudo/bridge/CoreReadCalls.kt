package io.github.monadboxlab.clashpseudo.bridge

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

import io.github.monadboxlab.clashpseudo.app.ApplicationContract
import io.github.monadboxlab.clashpseudo.app.AppMessage
import io.github.monadboxlab.clashpseudo.app.AppStrings

import io.github.monadboxlab.clashpseudo.R
import android.os.Handler
import android.os.Looper
import io.github.monadboxlab.clashpseudo.nativecore.CoreHost
import io.github.monadboxlab.clashpseudo.nativecore.NativeCore
import io.github.monadboxlab.clashpseudo.vpn.UnderlyingNetworks
import org.json.JSONObject
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class CoreReadCalls(
    private val core: CoreHost,
    private val getConfiguration: () -> String = { NativeCore.runtimeConfig() },
    private val timeoutMs: Long = 3000,
    private val getNodes: (ByteArray) -> String = { NativeCore.nodes(it) },
    private val getRules: (ByteArray) -> String = { NativeCore.rules(it) },
    private val getResources: () -> String = { NativeCore.resources() },
    private val getLogs: (ByteArray) -> String = { NativeCore.logs(it) },
    private val updateResource: (ByteArray) -> String = { NativeCore.updateResource(it) },
    private val updateWorker: Executor = resourceUpdates,
    private val updateChanged: () -> Unit = {},
    private val updateTimeoutMs: Long = 125000,
    private val queryDns: (ByteArray) -> String = { NativeCore.dnsQuery(it) },
    private val cancelDns: (Long) -> Unit = { NativeCore.cancelDnsQuery(it) },
    private val clearDns: () -> String = { NativeCore.clearDnsCache() },
    private val flushFakeIpNative: () -> String = { NativeCore.flushFakeIp() },
    private val dnsWorker: Executor = dnsQueries,
    private val dnsTimeoutMs: Long = ApplicationContract.DNS_BRIDGE_TIMEOUT_MS,
    private val networkEpoch: () -> Long = { UnderlyingNetworks.snapshot().revision },
) {
    companion object {
        private const val DNS_REPLY_BYTES = ApplicationContract.DNS_RESULT_BYTES
        private val dnsSequence = java.util.concurrent.atomic.AtomicLong()
        private val dnsQueries = Executors.newSingleThreadExecutor { task -> Thread(task, "PseudoDnsQuery") }
        // Use a dedicated process-wide I/O queue so core Stop can close TUN and cancel
        // providers.
        private val resourceUpdates = Executors.newSingleThreadExecutor { task ->
            Thread(task, "PseudoResourceUpdates")
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private var pending = false
    // Retain a timed-out read's completion for one exact matching continuation; retire
    // its reply callback.
    private data class PageKey(val identity: String, val query: String)
    private data class CompletedPage(
        val key: PageKey, val value: String?, val error: AppMessage?,
    )
    private var latestPage: PageKey? = null
    private var completedPage: CompletedPage? = null
    private var expirePage: Runnable? = null
    private fun clearCompletedPage() {
        completedPage = null
        expirePage?.let { main.removeCallbacks(it) }
        expirePage = null
    }
    @Volatile var updating = false
        private set

    @Volatile var dnsBusy = false
        private set
    private class DnsRequest(val generation: Long, val composition: String, val query: Boolean,
                             val owner: String?, val envelope: JSONObject, val epoch: Long,
                             val reply: (String?, AppMessage?) -> Unit) {
        val id = dnsSequence.incrementAndGet()
        val active = AtomicBoolean(true)
        lateinit var timeout: Runnable
    }
    private var dnsRequest: DnsRequest? = null

    fun handleDns(call: MethodCall, result: MethodChannel.Result) {
        val before = core.snapshot()
        val generation = when (val value = call.argument<Any>("generation")) {
            is Int -> value.toLong()
            is Long -> value
            else -> -1L
        }
        val revision = when (val value = call.argument<Any>("revision")) {
            is Int -> value.toLong()
            is Long -> value
            else -> -1L
        }
        val composition = call.argument<Any>("composition") as? String
        val queryOwner = call.argument<Any>("queryOwner") as? String
        val matches = generation > 0 && revision > 0 && !composition.isNullOrEmpty() &&
            before.generation == generation && before.composition == composition &&
            !before.configId.isNullOrEmpty() && before.configId == call.argument<Any>("configId") &&
            before.revision?.toLong() == revision && before.purpose != null &&
            before.purpose.name == call.argument<Any>("purpose")
        if ((call.method == "dnsQuery" || call.method == "cancelDnsQuery") &&
            (queryOwner.isNullOrEmpty() || queryOwner.length > 128)) {
            result.error("dns", null, AppStrings.message(R.string.error_core_context_reread).toMap())
            return
        }
        if (call.method == "cancelDnsQuery") {
            if (matches) cancelDnsQuery(generation, composition, queryOwner)
            result.success(null)
            return
        }
        if (!matches || !core.current(generation)) {
            result.error("dns", null, AppStrings.message(R.string.error_core_context_reread).toMap())
            return
        }
        val reply: (String?, AppMessage?) -> Unit = { value, error ->
            if (error != null) result.error("dns", null, error.toMap())
            else result.success(value)
        }
        when (call.method) {
            "dnsQuery" -> dnsQuery(generation, composition,
                call.argument<Map<String, Any?>>("query") ?: emptyMap(), queryOwner, reply)
            "clearDnsCache" -> clearDnsCache(generation, composition, reply)
            "flushFakeIp" -> flushFakeIp(generation, composition, reply)
        }
    }

    fun handleResourceUpdate(call: MethodCall, result: MethodChannel.Result, authorized: () -> Boolean) {
        val before = core.snapshot()
        val generation = call.argument<Number>("generation")?.toLong() ?: -1L
        val composition = call.argument<String>("composition")
        if (composition == null || before.generation != generation || before.composition != composition ||
            before.configId != call.argument<String>("configId") ||
            before.revision != call.argument<Int>("revision") ||
            before.purpose?.name != call.argument<String>("purpose")) {
            result.error("updateResource", null, AppStrings.message(R.string.error_core_context_reread).toMap())
            return
        }
        update(generation, composition,
            call.argument<Map<String, Any?>>("query") ?: emptyMap(),
            authorized = authorized) { value, error ->
            if (!authorized()) {
                result.error("expired", null, AppStrings.message(R.string.error_operation_ended).toMap())
            } else if (error != null) result.error("updateResource", null, error.toMap())
            else result.success(value)
        }
    }

    fun dnsQuery(generation: Long, composition: String?, request: Map<String, Any?>, owner: String? = null,
                 reply: (String?, AppMessage?) -> Unit) {
        // This trusted layer supplies the requestId associated with cancellation.
        val body = JSONObject().put("name", request["name"]).put("type", request["type"])
        dnsOperation(generation, composition, true, reply, owner) { token ->
            val bytes = body.put("requestId", token.id.toString()).toString().toByteArray(Charsets.UTF_8)
            if (bytes.size > ApplicationContract.DNS_REQUEST_BYTES) "{\"error\":\"invalidRequest\"}" else queryDns(bytes)
        }
    }

    fun clearDnsCache(generation: Long, composition: String?, reply: (String?, AppMessage?) -> Unit) =
        dnsOperation(generation, composition, false, reply) { clearDns() }

    fun flushFakeIp(generation: Long, composition: String?, reply: (String?, AppMessage?) -> Unit) =
        dnsOperation(generation, composition, false, reply) { flushFakeIpNative() }

    fun cancelDnsQuery(generation: Long, composition: String?, owner: String? = null) {
        val token = dnsRequest ?: return
        if (!token.query || token.generation != generation || token.composition != composition || token.owner != owner) return
        cancelDnsSafely(token)
        if (token.active.getAndSet(false)) {
            main.removeCallbacks(token.timeout)
            token.reply(encodeDnsResult(token.envelope, "dns", JSONObject().put("error", "cancelled")), null)
        }
        // Neither cancellation nor a reply timeout releases dnsBusy.
    }

    fun cancelDnsForBackground() {
        val token = dnsRequest ?: return
        cancelDnsQuery(token.generation, token.composition, token.owner)
    }

    private fun cancelDnsSafely(token: DnsRequest) {
        try { cancelDns(token.id) } catch (_: Exception) { } catch (_: LinkageError) { }
    }

    private fun encodeDnsResult(envelope: JSONObject, field: String, data: JSONObject): String {
        val encoded = envelope.put(field, data).toString()
        if (encoded.toByteArray(Charsets.UTF_8).size <= DNS_REPLY_BYTES) return encoded
        // Reject an oversized result while retaining its complete identity and
        // reserved error envelope.
        return envelope.put(field, JSONObject().put("error", "resultTooLarge")).toString()
    }

    private fun dnsOperation(generation: Long, composition: String?, query: Boolean,
                             reply: (String?, AppMessage?) -> Unit, owner: String? = null,
                             read: (DnsRequest) -> String) {
        val source = core.snapshot()
        if (composition == null || !core.current(generation) || source.composition != composition) {
            reply(null, AppStrings.message(R.string.error_core_context_reread)); return
        }
        val epoch = networkEpoch()
        val envelope = JSONObject().put("generation", generation).put("composition", composition)
            .put("configId", source.configId).put("revision", source.revision)
            .put("purpose", source.purpose?.name).put("networkEpoch", epoch)
        val field = if (query) "dns" else "cache"
        if (envelope.toString().toByteArray(Charsets.UTF_8).size > DNS_REPLY_BYTES - 128) {
            reply(null, AppStrings.message(R.string.error_core_read_failed)); return
        }
        if (dnsBusy) { reply(encodeDnsResult(envelope, field, JSONObject().put("error", "busy")), null); return }
        val token = DnsRequest(generation, composition, query, owner, envelope, epoch, reply)
        fun current() = core.current(generation) && core.snapshot().let {
            it.composition == composition && it.configId == source.configId && it.revision == source.revision && it.purpose == source.purpose
        } && networkEpoch() == epoch
        dnsRequest = token
        dnsBusy = true
        updateChanged()
        token.timeout = Runnable {
            if (token.active.getAndSet(false)) {
                if (query) cancelDnsSafely(token)
                if (current()) reply(encodeDnsResult(envelope, field, JSONObject().put("error", "timeout")), null)
                else reply(null, AppStrings.message(R.string.error_core_context_reread))
            }
        }
        main.postDelayed(token.timeout, dnsTimeoutMs)
        fun finish(value: JSONObject?, error: AppMessage?) {
            main.post {
                check(dnsRequest === token)
                dnsRequest = null
                dnsBusy = false
                main.removeCallbacks(token.timeout)
                updateChanged()
                if (token.active.getAndSet(false)) {
                    if (current()) reply(value?.let { encodeDnsResult(envelope, field, it) }, error)
                    else reply(null, AppStrings.message(R.string.error_core_context_reread))
                }
            }
        }
        try {
            core.worker.execute {
                if (!token.active.get() || !current() || !core.beginResourceUpdate(generation, composition)) {
                    finish(null, AppStrings.message(R.string.error_core_context_reread)); return@execute
                }
                try {
                    dnsWorker.execute {
                        var value: JSONObject? = null
                        var error: AppMessage? = null
                        try {
                            check(token.active.get() && current())
                            val raw = read(token)
                            value = if (raw.toByteArray(Charsets.UTF_8).size > DNS_REPLY_BYTES)
                                JSONObject().put("error", "resultTooLarge") else JSONObject(raw)
                        } catch (_: Exception) { error = AppStrings.message(R.string.error_core_read_failed) }
                        catch (_: LinkageError) { error = AppStrings.message(R.string.error_native_read_unavailable) }
                        finally { core.worker.execute { core.endResourceUpdate() } }
                        finish(value, error)
                    }
                } catch (_: Exception) {
                    core.endResourceUpdate()
                    finish(null, AppStrings.message(R.string.error_core_read_failed))
                }
            }
        } catch (_: Exception) { finish(null, AppStrings.message(R.string.error_core_read_failed)) }
    }

    fun read(generation: Long, composition: String?, reply: (String?, AppMessage?) -> Unit) =
        query(generation, composition, "configuration", { JSONObject(getConfiguration()) }, reply)

    fun resources(generation: Long, composition: String?, reply: (String?, AppMessage?) -> Unit) =
        // Project the resource row list from the core's resources envelope.
        query(generation, composition, "resources", {
            val data = JSONObject(getResources())
            if (data.has("error")) data else data.getJSONArray("resources")
        }, reply)

    fun update(generation: Long, composition: String?, request: Map<String, Any?>,
               authorized: () -> Boolean = { true },
               reply: (String?, AppMessage?) -> Unit) {
        val body = JSONObject(request).toString().toByteArray(Charsets.UTF_8)
        if (body.size > 4096) {
            reply(null, AppStrings.message(R.string.error_resource_update_size))
            return
        }
        val before = core.snapshot()
        if (updating || !authorized() || !core.current(generation) || composition == null || before.composition != composition) {
            reply(null, AppStrings.message(R.string.error_core_busy))
            return
        }
        updating = true
        updateChanged()
        val active = AtomicBoolean(true)
        val timeout = Runnable {
            if (active.getAndSet(false)) reply(null, AppStrings.message(R.string.error_core_read_timeout))
        }
        main.postDelayed(timeout, updateTimeoutMs)
        fun finish(value: String?, error: AppMessage?) {
            main.post {
                // Hold update admission until the native call returns, including after
                // reply timeout.
                updating = false
                updateChanged()
                main.removeCallbacks(timeout)
                if (active.getAndSet(false)) {
                    if (core.current(generation) && core.snapshot().composition == composition) reply(value, error)
                    else reply(null, AppStrings.message(R.string.error_core_context_reread))
                }
            }
        }
        core.worker.execute {
            if (!active.get() || !authorized() || !core.beginResourceUpdate(generation, composition)) {
                finish(null, AppStrings.message(R.string.error_core_context_reread))
                return@execute
            }
            try {
                updateWorker.execute {
                    var value: String? = null
                    var error: AppMessage? = null
                    try {
                        check(active.get() && authorized() && core.current(generation) && core.snapshot().composition == composition)
                        val data = JSONObject(updateResource(body))
                        value = JSONObject().put("update", data)
                            .put("generation", generation).put("configId", before.configId)
                            .put("revision", before.revision).put("composition", composition)
                            .put("purpose", before.purpose?.name).toString()
                    } catch (_: Exception) {
                        error = AppStrings.message(R.string.error_core_read_failed)
                    } catch (_: LinkageError) {
                        error = AppStrings.message(R.string.error_native_read_unavailable)
                    } finally {
                        core.worker.execute { core.endResourceUpdate() }
                    }
                    finish(value, error)
                }
            } catch (_: Exception) {
                core.endResourceUpdate()
                finish(null, AppStrings.message(R.string.error_core_read_failed))
            }
        }
    }

    fun nodes(generation: Long, composition: String?, request: Map<String, Any?>,
              reply: (String?, AppMessage?) -> Unit) {
        val body = JSONObject(request).toString().toByteArray(Charsets.UTF_8)
        if (body.size > 65536) {
            reply(null, AppStrings.message(R.string.error_nodes_query_size))
            return
        }
        query(generation, composition, "page", { JSONObject(getNodes(body)) }, reply, pageQuery = "nodes:" + body.toString(Charsets.UTF_8))
    }

    fun rules(generation: Long, composition: String?, request: Map<String, Any?>,
              reply: (String?, AppMessage?) -> Unit) {
        val body = JSONObject(request).toString().toByteArray(Charsets.UTF_8)
        if (body.size > 65536) {
            reply(null, AppStrings.message(R.string.error_rules_query_size))
            return
        }
        query(generation, composition, "page", { JSONObject(getRules(body)) }, reply, allowError = true, pageQuery = "rules:" + body.toString(Charsets.UTF_8))
    }

    fun logs(generation: Long, composition: String?, request: Map<String, Any?>,
             reply: (String?, AppMessage?) -> Unit) {
        val body = JSONObject(request).toString().toByteArray(Charsets.UTF_8)
        if (body.size > 4096) {
            reply(null, AppStrings.message(R.string.error_logs_query_size))
            return
        }
        val source = core.logSource()
        if (source == null || request["window"] != source.logWindow) {
            reply(null, AppStrings.message(R.string.error_core_context_reread))
            return
        }
        query(generation, composition, "logs", {
            val data = JSONObject(getLogs(body))
            check(data.getString("window") == source.logWindow)
            data
        }, reply, timeoutMs = 1500, logSource = source)
    }

    private fun query(generation: Long, composition: String?, field: String,
                      read: () -> Any, reply: (String?, AppMessage?) -> Unit, allowError: Boolean = false,
                      timeoutMs: Long = this.timeoutMs, logSource: CoreHost.Snapshot? = null,
                      pageQuery: String? = null) {
        val reportPending = pageQuery != null
        val before = logSource ?: core.snapshot()
        fun current(): Boolean {
            if (logSource != null) return core.logsCurrent(generation, composition, logSource.logWindow)
            val now = core.snapshot()
            return core.current(generation) && now.composition == composition &&
                (!reportPending || (before.generation == generation && now.generation == before.generation &&
                    now.configId == before.configId && now.revision == before.revision && now.purpose == before.purpose))
        }
        fun envelope(): JSONObject = JSONObject()
            .put("generation", generation).put("configId", before.configId)
            .put("revision", before.revision).put("composition", composition)
            .put("purpose", before.purpose?.name)
        if (!current() || composition == null || before.composition != composition) {
            latestPage = null
            clearCompletedPage()
            reply(null, AppStrings.message(R.string.error_core_busy))
            return
        }
        val identity = envelope().toString()
        val pageKey = pageQuery?.let { PageKey(identity, it) }
        if (pageKey != null) latestPage = pageKey
        val completed = completedPage
        if (completed != null && (pageKey != null || completed.key.identity != identity)) {
            clearCompletedPage()
            if (completed.key == pageKey) {
                latestPage = null
                reply(completed.value, completed.error)
                return
            }
        }
        if (pending) {
            if (reportPending) reply(envelope().put("readPending", true).toString(), null)
            else reply(null, AppStrings.message(R.string.error_core_busy))
            return
        }
        pending = true
        val active = AtomicBoolean(true)
        val timeout = Runnable {
            if (active.getAndSet(false)) {
                // Keep the slot through real native completion; readers retain only
                // their latest retry intent.
                if (reportPending && current()) reply(envelope().put("readPending", true).toString(), null)
                else reply(null, AppStrings.message(R.string.error_core_read_timeout))
            }
        }
        main.postDelayed(timeout, timeoutMs)
        core.worker.execute {
            var value: String? = null
            var error: AppMessage? = null
            try {
                // A page deadline ends its reply; matching continuations consume the
                // actual computation result.
                check((reportPending || active.get()) && current())
                val data = read()
                check(allowError || data !is JSONObject || !data.has("error"))
                value = envelope().put(field, data).toString()
            } catch (_: Exception) {
                error = AppStrings.message(R.string.error_core_read_failed)
            } catch (_: LinkageError) {
                error = AppStrings.message(R.string.error_native_read_unavailable)
            }
            main.post {
                pending = false
                main.removeCallbacks(timeout)
                if (active.getAndSet(false)) {
                    if (pageKey != null && latestPage == pageKey) latestPage = null
                    if (current()) reply(value, error)
                    else reply(null, AppStrings.message(R.string.error_core_context_reread))
                } else if (pageKey != null && latestPage == pageKey && current()) {
                    clearCompletedPage()
                    val completed = CompletedPage(pageKey, value, error)
                    completedPage = completed
                    val expiry = Runnable {
                        if (completedPage === completed) {
                            completedPage = null
                            expirePage = null
                            if (latestPage == pageKey) latestPage = null
                        }
                    }
                    expirePage = expiry
                    main.postDelayed(expiry, 10000)
                } else {
                    latestPage = null
                }
            }
        }
    }
}

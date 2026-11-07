package io.github.monadboxlab.clashpseudo.nativecore

import android.content.Context
import android.os.Build
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.os.Process
import android.os.SystemClock
import androidx.annotation.Keep
import io.github.monadboxlab.clashpseudo.app.AppProcess
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.nativecore.assets.BundledGeo
import io.github.monadboxlab.clashpseudo.nativecore.vpn.VpnSpecification
import io.github.monadboxlab.clashpseudo.storage.AppFiles
import io.github.monadboxlab.clashpseudo.trust.AppTrust
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import io.github.monadboxlab.clashpseudo.vpn.network.AndroidSystemDns
import io.github.monadboxlab.clashpseudo.vpn.network.UnderlyingNetworks
import io.github.monadboxlab.clashpseudo.vpn.network.UnderlyingSnapshot
import io.github.monadboxlab.clashpseudo.vpn.network.LocalInterfaces
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/** The sole system resource host in :core; it does not store content, delay batches, or application history. */
class CoreHost internal constructor(
    private val context: Context,
    private val statusChanged: (Bundle) -> Unit,
    private val requestExited: (Long, ByteArray) -> Unit,
) {
    enum class Phase { EMPTY, LOADING, READY, RELEASING, FAILED }
    enum class Purpose { PREVIEW, VPN, RUNNING }
    data class Snapshot(
        val generation: Long = 0, val phase: Phase = Phase.EMPTY, val purpose: Purpose? = null,
        val configId: String? = null, val revision: Int? = null,
        val error: io.github.monadboxlab.clashpseudo.message.AppMessage? = null,
        val composition: String? = null, val logWindow: String? = null,
        val processId: String? = null, val inputId: String? = null,
    ) {
        fun toMap(): Map<String, Any?> = mapOf("generation" to generation, "phase" to phase.name,
            "purpose" to purpose?.name, "configId" to configId, "revision" to revision,
            "error" to error?.toMap(), "composition" to composition, "logWindow" to logWindow,
            "processId" to processId, "inputId" to inputId)
    }

    val processId: String = UUID.randomUUID().toString()
    private val io = Executors.newCachedThreadPool { runnable -> Thread(runnable, "core-pipe") }
    private val workers = Executors.newCachedThreadPool { runnable -> Thread(runnable, "core-call") }
    private val control = Executors.newSingleThreadScheduledExecutor { runnable -> Thread(runnable, "core-control") }
    private val transport = CoreNativeTransport(context, io)
    private class Call : AtomicBoolean(true) {
        var started = false
    }
    private val calls = ConcurrentHashMap<Long, Call>()
    private val drained = Object()
    private val requestIds = CoreRequestIds()
    private val stopping = AtomicBoolean(false)
    private val prepared = AtomicBoolean(false)
    private var trustInitialized = false
    @Volatile private var phase = Contract.CORE_PHASE_CONNECTED
    @Volatile private var inputId: String? = null
    @Volatile private var generation = 0L
    @Volatile private var network: UnderlyingSnapshot = UnderlyingNetworks.snapshot()
    @Volatile private var callbacks: PlatformCallbacks? = null
    @Volatile private var vpnIntent = false
    @Volatile private var lanIntent = false
    @Volatile private var vpnRunning = false
    @Volatile private var runningSince: Long? = null
    @Volatile private var configId: String? = null
    @Volatile private var revision = 0
    @Volatile private var lastError: JSONObject? = null
    @Volatile private var access: Map<String, Any?>? = null
    @Volatile private var pathsState: JSONObject? = null
    @Volatile private var listenerState = JSONArray()
    @Volatile private var lanRunning = false
    @Volatile private var purpose: String? = null
    private data class LanBinding(val listenerName: String, val interfaceName: String, val interfaceIndex: Int, val address: String)
    private var lanBindings = emptyList<LanBinding>()
    private val invalidListeners = mutableSetOf<String>()
    private val localInterfaces = LocalInterfaces(context) { workers.execute { checkLanInterfaces() } }

    init { AppProcess.requireCore(context) }

    internal fun allocateRequestId(): Long = requestIds.next()
    internal fun document(bytes: ByteArray): ParcelFileDescriptor = transport.document(bytes)

    fun status(): Bundle = Bundle().apply {
        putInt(Contract.CORE_FIELD_PROTOCOL, Contract.CORE_IPC_VERSION)
        putString(Contract.CORE_FIELD_PROCESS_ID, processId)
        putInt("pid", Process.myPid())
        putString(Contract.CORE_FIELD_PHASE, phase)
        putString("purpose", purpose)
        putLong(Contract.CORE_FIELD_GENERATION, generation)
        putString(Contract.CORE_FIELD_INPUT_ID, inputId)
        putLong(Contract.CORE_FIELD_NETWORK_REVISION, network.revision)
        putString("configId", configId)
        putInt("revision", revision)
        putBoolean("vpnIntent", vpnIntent)
        putBoolean("lanIntent", lanIntent)
        putBoolean("vpnRunning", vpnRunning)
        putBoolean("lanRunning", lanRunning)
        pathsState?.let { putString("cleanupCandidates", it.toString()) }
        runningSince?.let { putLong("runningSinceElapsedMs", it) }
        PseudoVpnService.instance?.systemState()?.forEach { (key, value) -> if (value != null) putBoolean(key, value) }
        lastError?.let { putString(Contract.CORE_FIELD_ERROR, it.toString()) }
    }

    fun submit(request: Bundle, input: ParcelFileDescriptor, output: ParcelFileDescriptor): Bundle {
        CoreControl.identity(request, processId)
        val id = allocateRequestId()
        request.putLong(Contract.CORE_FIELD_REQUEST_ID, id)
        val operation = request.getInt(Contract.CORE_FIELD_OPERATION)
        check(request.getLong(Contract.CORE_FIELD_NETWORK_REVISION) == network.revision) { "Request does not belong to the captured Network revision" }
        if (phase == Contract.CORE_PHASE_READY) {
            check(request.getLong(Contract.CORE_FIELD_GENERATION) == generation && request.getString(Contract.CORE_FIELD_INPUT_ID) == inputId) {
                "Request does not belong to the current inputId/generation"
            }
        } else if (operation == Contract.CORE_OPERATION_PREPARE || operation == Contract.CORE_OPERATION_LOGS) {
            check(request.getLong(Contract.CORE_FIELD_GENERATION) == 1L && !request.getString(Contract.CORE_FIELD_INPUT_ID).isNullOrEmpty()) {
                "Preparation and startup LOGS require a new inputId/generation"
            }
        }
        if (id <= 0L || operation !in Contract.CORE_OPERATION_PREPARE..Contract.CORE_OPERATION_VPN_SPEC ||
            operation == Contract.CORE_OPERATION_ATTACH ||
            operation == Contract.CORE_OPERATION_SHUTDOWN || operation == Contract.CORE_OPERATION_STOP) {
            input.close(); output.close()
            throw IllegalArgumentException("Invalid core request operation or identity")
        }
        check(!stopping.get()) { "Core process is exiting" }
        val token = Call()
        check(calls.putIfAbsent(id, token) == null) { "Duplicate core request identity" }
        try {
            workers.execute {
                var receipt = JSONObject().put(Contract.CORE_FIELD_EXITED, true).toString().toByteArray(Charsets.UTF_8)
                var failure: Throwable? = null
                var preparationStarted = false
                try {
                    input.use { source ->
                        val target = output
                        val parts = ParcelFileDescriptor.AutoCloseInputStream(source).use(CoreParts::read)
                        val metadata = JSONObject(CoreFrames.utf8(parts.getValue(Contract.CORE_PART_REQUEST)))
                        verifyMetadata(request, metadata)
                        synchronized(token) {
                            if (!token.get()) throw CoreTransportException(Contract.CORE_ERROR_CANCELLED, "Request was cancelled before entering the core")
                            token.started = true
                        }
                        if (operation == Contract.CORE_OPERATION_PREPARE) {
                            check(prepared.compareAndSet(false, true)) { "Each core process can prepare only one context" }
                            preparationStarted = true
                            prepare(id, request, metadata, parts, target)
                        } else if (operation == Contract.CORE_OPERATION_PATHS) queryPaths(id, parts, target)
                        else if (operation == Contract.CORE_OPERATION_SNAPSHOT) querySnapshot(id, parts, target)
                        else {
                            CoreProcessResources.acquire(context)
                            if (operation == Contract.CORE_OPERATION_CANCEL) {
                                val targetId = metadata.getJSONObject("arguments").getLong("targetRequestId")
                                require(targetId > 0 && targetId != id) { "Invalid CANCEL targetRequestId" }
                                val started = calls[targetId]?.let { target -> synchronized(target) {
                                    val actual = target.started
                                    target.set(false)
                                    actual
                                } }
                                if (started != null) {
                                    ParcelFileDescriptor.AutoCloseOutputStream(ParcelFileDescriptor.dup(target.fileDescriptor)).use {
                                        CoreFrames.write(it, CoreFrames.Frame(Contract.CORE_IPC_FRAME_METADATA,
                                            JSONObject().put(Contract.CORE_FIELD_STARTED, started).toString().toByteArray(Charsets.UTF_8)))
                                    }
                                }
                            } else initializeTrust()
                            receipt = transport.stream(operation, id, parts, target, null, callback())
                        }
                    }
                } catch (error: Throwable) {
                    failure = error
                    lastError = CoreErrors.json(error)
                    receipt = CoreErrors.receipt(error)
                    try { writeFailure(output, error) } catch (close: Throwable) { if (close !== error) error.addSuppressed(close) }
                    if (preparationStarted) {
                        val expectedCancellation = error is CoreTransportException &&
                            error.code == Contract.CORE_ERROR_CANCELLED && stopping.get()
                        if (!expectedCancellation) {
                            phase = Contract.CORE_PHASE_RECOVERY_REQUIRED
                            statusChanged(status())
                            control.schedule({ selfExit() }, 100, TimeUnit.MILLISECONDS)
                        }
                    }
                } finally {
                    for (descriptor in listOf(input, output)) try { descriptor.close() } catch (error: Throwable) {
                        if (failure == null) failure = error else if (failure !== error) failure!!.addSuppressed(error)
                    }
                    failure?.let { lastError = CoreErrors.json(it); receipt = CoreErrors.receipt(it) }
                    try {
                        // Callbacks follow actual invoke, platform call, and FD close returns, not EOF or cancellation intent.
                        requestExited(id, receipt)
                    } finally {
                        calls.remove(id, token)
                        synchronized(drained) { drained.notifyAll() }
                    }
                }
            }
        } catch (error: Throwable) {
            calls.remove(id, token)
            input.close(); output.close()
            throw error
        }
        return Bundle().apply { putBoolean(Contract.CORE_FIELD_ACCEPTED, true); putLong(Contract.CORE_FIELD_REQUEST_ID, id) }
    }

    private fun verifyMetadata(control: Bundle, request: JSONObject) {
        if (request.getString(Contract.CORE_FIELD_PROCESS_ID) != processId ||
            request.getInt(Contract.CORE_FIELD_PROTOCOL) != Contract.CORE_IPC_VERSION ||
            request.getInt(Contract.CORE_FIELD_OPERATION) != control.getInt(Contract.CORE_FIELD_OPERATION) ||
            request.getLong(Contract.CORE_FIELD_NETWORK_REVISION) != control.getLong(Contract.CORE_FIELD_NETWORK_REVISION) ||
            request.getLong(Contract.CORE_FIELD_REQUEST_ID) != control.getLong(Contract.CORE_FIELD_REQUEST_ID) ||
            request.getLong(Contract.CORE_FIELD_GENERATION) != control.getLong(Contract.CORE_FIELD_GENERATION) ||
            request.optString(Contract.CORE_FIELD_INPUT_ID) != control.getString(Contract.CORE_FIELD_INPUT_ID).orEmpty()) {
            throw CoreTransportException(Contract.CORE_ERROR_IDENTITY_MISMATCH, "Pipe request does not match the control identity")
        }
    }

    private fun prepare(id: Long, controlRequest: Bundle, request: JSONObject,
                        originalParts: Map<String, ByteArray>, output: ParcelFileDescriptor) {
        CoreProcessResources.acquire(context)
        check(controlRequest.getLong(Contract.CORE_FIELD_GENERATION) == 1L) { "A new core process must have generation 1" }
        val arguments = request.getJSONObject("arguments")
        val purpose = arguments.getString("purpose")
        this.purpose = purpose
        check(purpose in setOf(Contract.CORE_PURPOSE_PREVIEW, Contract.CORE_PURPOSE_RUNNING)) { "Invalid core purpose" }
        inputId = controlRequest.getString(Contract.CORE_FIELD_INPUT_ID)?.takeIf { it.isNotBlank() }
            ?: throw IllegalArgumentException("Core preparation is missing inputId")
        generation = controlRequest.getLong(Contract.CORE_FIELD_GENERATION).coerceAtLeast(1L)
        configId = arguments.optStringOrNull("configId") ?: arguments.optStringOrNull("id")
        revision = arguments.optInt("revision")
        vpnIntent = purpose == Contract.CORE_PURPOSE_RUNNING && arguments.optBoolean("vpnIntent")
        lanIntent = purpose == Contract.CORE_PURPOSE_RUNNING && arguments.optBoolean("lanIntent")
        val selected = arguments.optJSONArray("lanInterfaces") ?: JSONArray()
        lanBindings = (0 until selected.length()).map { index ->
            val row = selected.getJSONObject(index)
            LanBinding(row.getString("listenerName"), row.getString("interfaceName"), row.getInt("interfaceIndex"), row.getString("address"))
        }
        check(!lanIntent || lanBindings.isNotEmpty()) { "LAN proxy has no selected interface address" }
        check(lanBindings.map { it.listenerName }.distinct().size == lanBindings.size) { "Duplicate LAN listenerName" }
        lanBindings.forEach { selectedAddress ->
            check(localInterfaces.available(selectedAddress.interfaceName, selectedAddress.interfaceIndex, selectedAddress.address)) { "Selected LAN interface address is no longer available: ${selectedAddress.address}" }
        }
        check(UnderlyingNetworks.snapshot().key == network.key) { "Underlying network has changed; a new core process is required" }
        phase = Contract.CORE_PHASE_LOADING
        statusChanged(status())
        CorePreparationObserver.beforeNativePrepare(context, processId, checkNotNull(inputId), configId,
            revision, id, arguments.getLong(Contract.CORE_FIELD_DEADLINE)) { stopping.get() || calls[id]?.get() != true }
        if (stopping.get() || calls[id]?.get() != true) {
            throw CoreTransportException(Contract.CORE_ERROR_CANCELLED, "PREPARE was cancelled before native preparation")
        }
        val options = JSONObject(CoreFrames.utf8(originalParts.getValue(Contract.CORE_PART_OPTIONS)))
        options.put("purpose", purpose).put("generation", generation).put("network", network.json())
            .put("vpnIntent", vpnIntent).put("lanIntent", lanIntent)
        val home = AppFiles.core(context)
        check(home.isDirectory || home.mkdirs()) { "Cannot create the private core data directory" }
        arguments.put("home", home.path)
        request.put("generation", generation).put("networkRevision", network.revision)
        val parts = originalParts.toMutableMap().apply {
            put(Contract.CORE_PART_OPTIONS, options.toString().toByteArray(Charsets.UTF_8))
            put(Contract.CORE_PART_REQUEST, request.toString().toByteArray(Charsets.UTF_8))
        }
        val accessMode = arguments.optString("access", "all")
        val packages = arguments.optJSONArray("packages")?.let { list -> (0 until list.length()).map(list::getString) }.orEmpty()
        callback()
        if (vpnIntent) PseudoVpnService.awaitResourceHost(context, arguments.getLong(Contract.CORE_FIELD_DEADLINE))
        initializeTrust()
        val pathsId = allocateRequestId()
        pathsState = readPaths(pathsId, nativeParts(Contract.CORE_OPERATION_PATHS, pathsId, JSONObject().put("home", home.path)))
        statusChanged(status())
        val preparedResult = transport.result(Contract.CORE_OPERATION_PREPARE, id, parts, null, callback())
        ensureSuccess(preparedResult)
        val value = preparedResult.value
        listenerState = value.optJSONArray("listeners") ?: JSONArray()
        lanRunning = lanIntent && listenersRunning(listenerState)
        localInterfaces.setActive(lanIntent)
        if (vpnIntent) {
            val specification = VpnSpecification.read(value.getJSONObject("vpnSpec").toString())
            check(specification.generation == generation && specification.networkKey == network.key) { "VPN specification does not match the current preparation" }
            val service = checkNotNull(PseudoVpnService.instance) { "VPN system resource host is unavailable" }
            val attached = service.establish(specification, accessMode, packages, network)
            access = attached.second
            val attachId = allocateRequestId()
            val attachParts = nativeParts(Contract.CORE_OPERATION_ATTACH, attachId, JSONObject().put("revision", specification.revision))
            ensureSuccess(transport.result(Contract.CORE_OPERATION_ATTACH, attachId, attachParts, attached.first, callback()))
            vpnRunning = true
            runningSince = SystemClock.elapsedRealtime()
            service.running()
        }
        phase = Contract.CORE_PHASE_READY
        value.put("platform", JSONObject().put("vpn", JSONObject().put("running", vpnRunning)
            .put("applicationAccess", access?.let(::JSONObject) ?: JSONObject.NULL))
            .put("lan", JSONObject().put("running", lanRunning)))
            .put(Contract.CORE_FIELD_PROCESS_ID, processId).put(Contract.CORE_FIELD_INPUT_ID, inputId)
            .put(Contract.CORE_FIELD_GENERATION, generation).put(Contract.CORE_FIELD_NETWORK_REVISION, network.revision)
        val sink = ParcelFileDescriptor.AutoCloseOutputStream(ParcelFileDescriptor.dup(output.fileDescriptor))
        sink.use {
            CoreFrames.write(it, CoreFrames.Frame(Contract.CORE_IPC_FRAME_DATA, value.toString().toByteArray(Charsets.UTF_8)))
            CoreFrames.write(it, CoreFrames.Frame(Contract.CORE_IPC_FRAME_TERMINAL,
                preparedResult.terminal.put(Contract.CORE_FIELD_EXITED, true).toString().toByteArray(Charsets.UTF_8)))
        }
        statusChanged(status())
    }

    private fun listenersRunning(listeners: JSONArray): Boolean {
        val rows = (0 until listeners.length()).map(listeners::getJSONObject)
        return lanBindings.isNotEmpty() && lanBindings.all { binding ->
            val selected = rows.filter { it.optString("name") == binding.listenerName }
            selected.isNotEmpty() && selected.all { it.optString("state") == "bound" }
        }
    }

    @Synchronized private fun checkLanInterfaces() {
        if (!lanIntent || phase != Contract.CORE_PHASE_READY || stopping.get()) return
        val invalid = lanBindings.filter { it.listenerName !in invalidListeners &&
            !localInterfaces.available(it.interfaceName, it.interfaceIndex, it.address) }.map { it.listenerName }
        if (invalid.isEmpty()) return
        invalidListeners.addAll(invalid)
        val id = allocateRequestId()
        try {
            val result = transport.result(Contract.CORE_OPERATION_RESOURCE_UPDATE, id,
                nativeParts(Contract.CORE_OPERATION_RESOURCE_UPDATE, id,
                    JSONObject().put("action", "closeListeners").put("names", JSONArray(invalid))), null, callback())
            ensureSuccess(result)
            val outcomes = result.value.getJSONArray("listeners")
            for (index in 0 until outcomes.length()) {
                val outcome = outcomes.getJSONObject(index)
                for (rowIndex in 0 until listenerState.length()) {
                    val listener = listenerState.getJSONObject(rowIndex)
                    if (listener.optString("name") == outcome.getString("name")) {
                        listener.put("state", if (outcome.optBoolean("closed")) "closed" else "closeFailed")
                        listener.put("error", outcome.opt("error") ?: JSONObject.NULL)
                    }
                }
            }
            lanRunning = false
            statusChanged(status().apply { putString("event", "listenersChanged") })
        } catch (error: Throwable) {
            lanRunning = false
            lastError = CoreErrors.json(error)
            statusChanged(status().apply { putString("event", "listenersChanged") })
        }
    }

    private fun readPaths(id: Long, parts: Map<String, ByteArray>): JSONObject {
        CoreProcessResources.acquire(context)
        val result = transport.result(Contract.CORE_OPERATION_PATHS, id, parts, null, callback())
        ensureSuccess(result)
        return result.value.put("home", AppFiles.core(context).path)
    }

    private fun queryPaths(id: Long, parts: Map<String, ByteArray>, output: ParcelFileDescriptor) {
        val request = JSONObject(CoreFrames.utf8(parts.getValue(Contract.CORE_PART_REQUEST)))
        request.getJSONObject("arguments").put("home", AppFiles.core(context).path)
        val actual = parts + (Contract.CORE_PART_REQUEST to request.toString().toByteArray(Charsets.UTF_8))
        val value = readPaths(id, actual)
        pathsState = value
        statusChanged(status())
        ParcelFileDescriptor.AutoCloseOutputStream(ParcelFileDescriptor.dup(output.fileDescriptor)).use {
            CoreFrames.write(it, CoreFrames.Frame(Contract.CORE_IPC_FRAME_DATA, value.toString().toByteArray(Charsets.UTF_8)))
            CoreFrames.write(it, CoreFrames.Frame(Contract.CORE_IPC_FRAME_TERMINAL,
                JSONObject().put("complete", true).put("exited", true).toString().toByteArray(Charsets.UTF_8)))
        }
    }

    private fun querySnapshot(id: Long, parts: Map<String, ByteArray>, output: ParcelFileDescriptor) {
        val result = transport.result(Contract.CORE_OPERATION_SNAPSHOT, id, parts, null, callback())
        ensureSuccess(result)
        val value = result.value.put("listeners", listenerState)
            .put("platform", JSONObject().put("vpn", JSONObject().put("running", vpnRunning)
                .put("applicationAccess", access?.let(::JSONObject) ?: JSONObject.NULL))
                .put("lan", JSONObject().put("running", lanRunning)))
        ParcelFileDescriptor.AutoCloseOutputStream(ParcelFileDescriptor.dup(output.fileDescriptor)).use {
            CoreFrames.write(it, CoreFrames.Frame(Contract.CORE_IPC_FRAME_DATA, value.toString().toByteArray(Charsets.UTF_8)))
            CoreFrames.write(it, CoreFrames.Frame(Contract.CORE_IPC_FRAME_TERMINAL, result.terminal.toString().toByteArray(Charsets.UTF_8)))
        }
    }

    private fun ensureSuccess(result: CoreNativeTransport.Result) {
        val receipt = JSONObject(CoreFrames.utf8(result.receipt))
        val error = receipt.optJSONObject(Contract.CORE_FIELD_ERROR) ?: result.terminal.optJSONObject(Contract.CORE_FIELD_ERROR)
            ?: result.value.optJSONObject(Contract.CORE_FIELD_ERROR)
        if (error != null) throw CoreNativeResultException(result, error)
        if (!result.terminal.optBoolean(Contract.CORE_FIELD_COMPLETE)) throw IOException("Core resource call has no complete terminal frame")
    }

    @Synchronized private fun initializeTrust() {
        if (trustInitialized) return
        val id = allocateRequestId()
        val parts = nativeParts(Contract.CORE_OPERATION_INITIALIZE_TRUST, id, JSONObject()) +
            (Contract.CORE_PART_TRUST to AppTrust.pem(context).toByteArray(Charsets.UTF_8))
        ensureSuccess(transport.result(Contract.CORE_OPERATION_INITIALIZE_TRUST, id, parts, null, callback()))
        trustInitialized = true
    }

    private fun nativeParts(operation: Int, id: Long, arguments: JSONObject): Map<String, ByteArray> =
        mapOf(Contract.CORE_PART_REQUEST to JSONObject().put(Contract.CORE_FIELD_PROTOCOL, Contract.CORE_IPC_VERSION)
            .put(Contract.CORE_FIELD_PROCESS_ID, processId).put(Contract.CORE_FIELD_INPUT_ID, inputId.orEmpty())
            .put(Contract.CORE_FIELD_GENERATION, generation).put(Contract.CORE_FIELD_REQUEST_ID, id)
            .put(Contract.CORE_FIELD_OPERATION, operation).put(Contract.CORE_FIELD_NETWORK_REVISION, network.revision)
            .put("arguments", arguments).toString().toByteArray(Charsets.UTF_8))

    private fun callback(): PlatformCallbacks = callbacks ?: synchronized(this) {
        callbacks ?: PlatformCallbacks(context, network, AppFiles.core(context), { vpnIntent }) { version, changed ->
            if (!stopping.get()) statusChanged(status().apply {
                putString("event", "specificationChanged"); putLong("specificationRevision", version); putBoolean("changed", changed)
            })
        }.also { callbacks = it }
    }

    fun exit(request: Bundle) {
        CoreControl.identity(request, processId)
        val admittedAt = request.getLong(Contract.CORE_FIELD_ADMITTED_AT)
        val deadline = request.getLong(Contract.CORE_FIELD_DEADLINE)
        require(admittedAt >= 0 && deadline >= admittedAt && deadline - admittedAt <= Contract.OPERATION_BACKUP_TIMEOUT_MS) {
            "Exit request has no valid original admission budget"
        }
        if (!stopping.compareAndSet(false, true)) return
        transport.closeAdmission()
        phase = Contract.CORE_PHASE_STOPPING
        val remaining = (deadline - SystemClock.elapsedRealtime()).coerceAtLeast(0L)
        control.schedule({ selfExit() }, remaining, TimeUnit.MILLISECONDS)
        try { statusChanged(status()) } catch (error: Throwable) { lastError = CoreErrors.json(error) }
        try { workers.execute {
            var failure: Throwable? = null
            fun record(error: Throwable) { if (failure == null) failure = error else if (failure !== error) failure!!.addSuppressed(error) }
            try {
                calls.values.forEach { it.set(false) }
                try { callbacks?.close() } catch (error: Throwable) { record(error) }
                try { PseudoVpnService.instance?.closeResources() } catch (error: Throwable) { record(error) }
                if (trustInitialized) {
                    try {
                        val id = allocateRequestId()
                        ensureSuccess(transport.result(Contract.CORE_OPERATION_SHUTDOWN, id, nativeParts(Contract.CORE_OPERATION_SHUTDOWN, id,
                            JSONObject().put("reason", request.getString("reason")).put(Contract.CORE_FIELD_DEADLINE, deadline)), null, callback()))
                    } catch (error: Throwable) { record(error) }
                }
                failure?.let { lastError = CoreErrors.json(it); statusChanged(status()) }
            } finally {
                synchronized(drained) {
                    while (calls.isNotEmpty()) {
                        val left = deadline - SystemClock.elapsedRealtime()
                        if (left <= 0) break
                        drained.wait(left)
                    }
                }
                transport.awaitIdle(deadline)
                callbacks?.awaitIdle(deadline)
                selfExit(normal = calls.isEmpty() && callbacks?.idle != false && transport.sealIfIdle())
            }
        } } catch (error: Throwable) {
            lastError = CoreErrors.json(error)
            try { statusChanged(status()) } catch (report: Throwable) { if (report !== error) error.addSuppressed(report) }
            throw error
        }
    }

    fun revoked(error: Throwable? = null) {
        vpnRunning = false
        access = null
        if (error != null) lastError = CoreErrors.json(error)
        statusChanged(status().apply { putString("event", "revoked") })
    }

    fun networkChanged() {
        val changed = UnderlyingNetworks.snapshot()
        if (stopping.get() || !prepared.get()) return
        statusChanged(status().apply {
            putString("event", "networkChanged"); putLong("nextNetworkRevision", changed.revision)
            putBoolean("changed", changed.key != network.key)
        })
    }

    private fun selfExit(normal: Boolean = false) = CoreProcessExit.exit(context, processId, normal)

    private fun writeFailure(output: ParcelFileDescriptor, error: Throwable) {
        ParcelFileDescriptor.AutoCloseOutputStream(ParcelFileDescriptor.dup(output.fileDescriptor)).use {
            CoreFrames.write(it, CoreFrames.Frame(Contract.CORE_IPC_FRAME_TERMINAL,
                JSONObject().put(Contract.CORE_FIELD_COMPLETE, false).put(Contract.CORE_FIELD_ERROR, CoreErrors.json(error))
                    .put(Contract.CORE_FIELD_EXITED, true).toString().toByteArray(Charsets.UTF_8)))
        }
    }

    @Keep
    private class PlatformCallbacks(
        private val context: Context,
        private val network: UnderlyingSnapshot,
        private val home: File,
        private val vpnIntent: () -> Boolean,
        private val specification: (Long, Boolean) -> Unit,
    ) : BundledGeo.Owner {
        private val active = AtomicBoolean(true)
        private val dnsExecutor = Executors.newCachedThreadPool { runnable -> Thread(runnable, "core-system-dns") }
        private val dns = AndroidSystemDns(network, dnsExecutor)
        override fun checkCurrent() = check(active.get()) { "The context owning the core resource has ended" }
        override fun publishIfCurrent(block: () -> Unit) = synchronized(this) { checkCurrent(); block() }
        @Keep fun protect(fd: Int): ByteArray = protectResult {
            checkCurrent()
            if (vpnIntent()) check(checkNotNull(PseudoVpnService.instance).protect(fd)) { "Android refused to protect the inbound socket" }
        }
        @Keep fun protectNetwork(fd: Int, networkHandle: String): ByteArray = protectResult {
            checkCurrent()
            if (vpnIntent()) check(checkNotNull(PseudoVpnService.instance).protect(fd)) { "Android refused to protect the outbound socket" }
            check(network.bindSocket(fd, networkHandle)) { "Outbound socket does not belong to the captured underlying network" }
        }
        private fun protectResult(action: () -> Unit): ByteArray = try {
            action(); JSONObject().put("ok", true).put("error", JSONObject.NULL).toString().toByteArray(Charsets.UTF_8)
        } catch (error: Throwable) { JSONObject().put("ok", false).put("error", CoreErrors.json(error)).toString().toByteArray(Charsets.UTF_8) }
        @Keep fun systemDns(requestId: Long, wire: ByteArray): ByteArray = dns.raw(requestId, wire)
        @Keep fun systemLookup(requestId: Long, host: String, family: Int): ByteArray = dns.lookup(requestId, host, family)
        @Keep fun cancelSystemDns(requestId: Long): ByteArray = dns.cancel(requestId)
        @Keep fun specificationChanged(revision: Long, changed: Boolean) { if (active.get()) specification(revision, changed) }
        @Keep fun seedGeo(request: ByteArray): ByteArray = try {
            checkCurrent()
            val values = JSONArray(CoreFrames.utf8(request))
            val requests = (0 until values.length()).map { index ->
                val value = values.getJSONObject(index)
                BundledGeo.Request(BundledGeo.Kind.entries.single { it.geoxKey == value.getString("kind") }, value.getString("targetName"))
            }
            BundledGeo(context).install(home, requests, this)
            JSONObject().put("ok", true).put("error", JSONObject.NULL).toString().toByteArray(Charsets.UTF_8)
        } catch (error: Throwable) { JSONObject().put("ok", false).put("error", CoreErrors.json(error)).toString().toByteArray(Charsets.UTF_8) }
        val idle: Boolean get() = dns.idle
        fun awaitIdle(deadline: Long) = dns.awaitIdle(deadline)
        fun close() {
            synchronized(this) { active.set(false) }
            val receipt = JSONObject(CoreFrames.utf8(dns.close()))
            receipt.optJSONObject("error")?.let { throw IOException(it.toString()) }
        }
    }
}

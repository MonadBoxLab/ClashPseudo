package io.github.monadboxlab.clashpseudo.nativecore

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Build
import android.os.Bundle
import android.os.DeadObjectException
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.monadboxlab.clashpseudo.MainActivity
import io.github.monadboxlab.clashpseudo.R
import io.github.monadboxlab.clashpseudo.app.AppProcess
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.message.AppMessage
import io.github.monadboxlab.clashpseudo.message.AppStrings
import io.github.monadboxlab.clashpseudo.nativecore.input.CoreInput
import io.github.monadboxlab.clashpseudo.nativecore.ipc.ICoreCallback
import io.github.monadboxlab.clashpseudo.nativecore.ipc.ICoreService
import io.github.monadboxlab.clashpseudo.storage.AppFiles
import io.github.monadboxlab.clashpseudo.storage.CoreDataCleanup
import io.github.monadboxlab.clashpseudo.vpn.NativeSession
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

/** The sole core connection in the default process; all state transitions run on a serial thread. */
class CoreClient private constructor(private val context: Context) {
    val lifecycle = CoreLifecycleRecord.forApplication(context)
    private val main = Handler(Looper.getMainLooper())
    private val state = Handler(HandlerThread("core-client-state").apply { start() }.looper)
    val io = Executors.newCachedThreadPool { runnable -> Thread(runnable, "core-client-io") }
    private val calls = ConcurrentHashMap<Pair<String, Long>, Call>()
    private val handshakeWaiters = mutableListOf<(Map<String, Any?>?, Throwable?) -> Unit>()
    private val exitWaiters = mutableMapOf<(Throwable?) -> Unit, String>()
    private var binding: Binding? = null
    @Volatile private var connection: Connection? = null
    @Volatile private var inputReads = 0
    @Volatile private var statusValue: Map<String, Any?> = mapOf(
        Contract.CORE_FIELD_PHASE to Contract.CORE_PHASE_DISCONNECTED)
    @Volatile var onEvent: (Map<String, Any?>) -> Unit = {}
    @Volatile var changed: (Boolean) -> Unit = {}
    val view = View()
    val resourceBusy: Boolean get() = calls.values.any { it.operation == Contract.CORE_OPERATION_RESOURCE_UPDATE && !it.drained }
    val requestBusy: Boolean get() = inputReads != 0 || documentReads.isNotEmpty() ||
        calls.values.any { it.operation != Contract.CORE_OPERATION_LOGS && !it.drained }
    private var visible = false
    private var operationBusy = false
    private var hiddenAt = SystemClock.elapsedRealtime()
    private val previewIdle = Runnable { releaseIdlePreview() }

    private val documentReads = java.util.concurrent.ConcurrentHashMap<ParcelFileDescriptor, String>()

    private class Call(
        val processId: String,
        val id: Long,
        val operation: Int,
        val inputId: String?,
        val composition: String?,
        val generation: Long,
        val networkRevision: Long,
        val input: ParcelFileDescriptor,
        val output: ParcelFileDescriptor,
        val owner: String?,
    ) {
        val reader = CoreFrames.Reader(ParcelFileDescriptor.AutoCloseInputStream(output))
        val exited = CountDownLatch(1)
        @Volatile var nativeExited = false
        @Volatile var nativeReceipt: JSONObject? = null
        @Volatile var receiptDescriptor: ParcelFileDescriptor? = null
        @Volatile var receiptExited = false
        @Volatile var reading = false
        @Volatile var terminal = false
        @Volatile var ioExited = false
        @Volatile var writeExited = false
        @Volatile var failure: Throwable? = null
        val drained: Boolean get() = nativeExited && receiptExited && ioExited && writeExited
    }

    private inner class Binding : ServiceConnection {
        var bound = false
        override fun onServiceConnected(name: ComponentName, binder: IBinder) { state.post { connected(this, binder) } }
        override fun onServiceDisconnected(name: ComponentName) { state.post { communicationLost(this, IOException("Core service connection was interrupted")) } }
        override fun onBindingDied(name: ComponentName) { state.post { communicationLost(this, IOException("Core service binding is no longer valid")) } }
        override fun onNullBinding(name: ComponentName) { state.post { communicationLost(this, IOException("Core service did not return a control interface")) } }
    }
    private class Connection(val binding: Binding, val remote: ICoreService, val binder: IBinder, val death: IBinder.DeathRecipient) {
        var processId = ""
        var deathLinked = false
        @Volatile var confirmedDead = false
        var callback: ICoreCallback? = null
        var statusSequence = 0L
        var recoverySource: Map<String, Any?>? = null
    }

    private fun source(value: Map<String, Any?>): Map<String, Any?> = listOf(
        Contract.CORE_FIELD_PROTOCOL, Contract.CORE_FIELD_PROCESS_ID, Contract.CORE_FIELD_INPUT_ID, Contract.CORE_FIELD_GENERATION,
        Contract.CORE_FIELD_NETWORK_REVISION, "configId", "revision", "purpose", "vpnIntent", "lanIntent",
    ).associateWith { key -> (value[key] as? Number)?.toLong() ?: value[key] }

    private fun sameSource(first: Map<String, Any?>, second: Map<String, Any?>): Boolean =
        !(first[Contract.CORE_FIELD_PROCESS_ID] as? String).isNullOrEmpty() && source(first) == source(second)

    private fun currentStatus(owner: Connection, captured: Map<String, Any?>): Boolean {
        val current = statusValue
        return connection === owner && !owner.confirmedDead && owner.binder.isBinderAlive && sameSource(current, captured) &&
            current[Contract.CORE_FIELD_PHASE] == captured[Contract.CORE_FIELD_PHASE]
    }

    private fun restoreInput(owner: Connection) {
        val captured = statusValue
        if (captured[Contract.CORE_FIELD_PHASE] != Contract.CORE_PHASE_READY ||
            captured["purpose"] != Contract.CORE_PURPOSE_RUNNING) {
            owner.recoverySource = null
            return
        }
        if (captured[Contract.CORE_FIELD_COMPOSITION] is String || !currentStatus(owner, captured)) return
        val source = source(captured)
        if (source == owner.recoverySource) return
        val inputId = captured[Contract.CORE_FIELD_INPUT_ID] as? String ?: return
        val configId = captured["configId"] as? String ?: return
        val revision = (captured["revision"] as? Number)?.toInt() ?: return
        owner.recoverySource = source
        inputReads++
        io.execute {
            val composition = runCatching {
                check(currentStatus(owner, captured)) { "Core changed before reading its immutable input" }
                val bytes = CorePrivateFiles.read(AppFiles.runRecord(context, inputId), AppFiles.MAX_RUN_RECORD_BYTES)
                    ?: throw IOException("Actual preparation input record does not exist")
                val raw = JSONObject(CoreFrames.utf8(bytes))
                check(raw.getString(Contract.CORE_FIELD_INPUT_ID) == inputId) { "Run input record identity changed" }
                check(raw.optBoolean("vpnIntent") == captured["vpnIntent"] && raw.optBoolean("lanIntent") == captured["lanIntent"]) {
                    "Run input intent changed"
                }
                CoreInput.read(raw, configId, revision, raw.optStringOrNull("mode")).composition
            }.getOrNull()
            state.post {
                inputReads--
                if (composition != null && owner.recoverySource === source && currentStatus(owner, captured) &&
                    statusValue[Contract.CORE_FIELD_COMPOSITION] == null) {
                    publish(statusValue + (Contract.CORE_FIELD_COMPOSITION to composition))
                    emit(source + mapOf("event" to Contract.CORE_EVENT_INPUT_RESTORED,
                        Contract.CORE_FIELD_PHASE to statusValue[Contract.CORE_FIELD_PHASE]))
                } else main.post { changed(false) }
            }
        }
    }

    init {
        AppProcess.requireApplication(context)
        state.post {
            try {
                val gate = CoreResourceGate.forApplication(context).tryAcquire()
                val locked = gate == null
                gate?.close()
                lifecycle.initialize(locked)
                publish(statusValue)
                if (locked) handshake { _, _ -> }
            } catch (error: Throwable) {
                publish(mapOf(Contract.CORE_FIELD_PHASE to Contract.CORE_PHASE_COMMUNICATION_LOST,
                    Contract.CORE_FIELD_ERROR to CoreErrors.json(error).toString()))
            }
        }
    }

    fun status(): Map<String, Any?> = statusValue + mapOf("recoveryRequired" to lifecycle.snapshot().recoveryRequired,
        "coreLifecycle" to lifecycle.snapshot().json().objectMap())

    fun refreshPresentation(reply: (Throwable?) -> Unit) {
        state.post {
            try { refreshRecoveryNotice() }
            catch (error: Throwable) { main.post { reply(error) }; return@post }
            val current = connection
            if (current == null || current.confirmedDead) {
                publish(statusValue + mapOf("alwaysOn" to null, "lockdown" to null))
                main.post { reply(null) }; return@post
            }
            try {
                acceptStatus(current, current.remote.status(identity(current.processId))) { error -> main.post { reply(error) } }
            } catch (error: Throwable) {
                publish(statusValue + mapOf("alwaysOn" to null, "lockdown" to null))
                communicationLost(current.binding, error)
                main.post { reply(error) }
            }
        }
    }

    fun handshake(reply: (Map<String, Any?>?, Throwable?) -> Unit) {
        state.post {
            val current = connection
            if (current != null) {
                if (current.confirmedDead || !current.binder.isBinderAlive) {
                    main.post { reply(null, IOException("Core exit has not finished; process death is not yet confirmed")) }
                    return@post
                }
                if (current.processId.isEmpty()) {
                    handshakeWaiters.add(reply)
                    establish(current)
                    return@post
                }
                try {
                    val snapshot = current.remote.status(identity(current.processId))
                    acceptStatus(current, snapshot)
                    main.post { reply(status(), null) }
                } catch (error: Throwable) {
                    communicationLost(current.binding, error)
                    main.post { reply(null, error) }
                }
                return@post
            }
            if (calls.isNotEmpty() || documentReads.isNotEmpty()) {
                main.post { reply(null, IOException("Local FD I/O for the old core process has not finished")) }
                return@post
            }
            handshakeWaiters.add(reply)
            if (binding != null) return@post
            try {
                val next = Binding()
                binding = next
                next.bound = context.bindService(Intent(context, CoreService::class.java), next, Context.BIND_AUTO_CREATE)
                if (!next.bound) throw IOException("Android did not establish the core service connection")
            } catch (error: Throwable) { failHandshake(error) }
        }
    }

    private fun connected(owner: Binding, binder: IBinder) {
        if (binding !== owner || !owner.bound) return
        val remote = ICoreService.Stub.asInterface(binder)
        lateinit var connected: Connection
        val death = IBinder.DeathRecipient { state.post { died(connected) } }
        connected = Connection(owner, remote, binder, death)
        connection = connected
        establish(connected)
    }

    private fun establish(connected: Connection) {
        try {
            if (!connected.deathLinked) {
                connected.binder.linkToDeath(connected.death, 0)
                connected.deathLinked = true
            }
            val callback = connected.callback ?: object : ICoreCallback.Stub() {
                override fun onStatus(snapshot: Bundle) {
                    CoreControl.sameUid(); CoreControl.check(snapshot)
                    state.post {
                        try { acceptStatus(connected, snapshot) }
                        catch (error: Throwable) { communicationLost(connected.binding, error) }
                    }
                }
                override fun onExited(processId: String, requestId: Long, receipt: ParcelFileDescriptor) {
                    CoreControl.sameUid()
                    state.post {
                        val call = calls[processId to requestId]
                        if (connection !== connected || connected.processId != processId || connected.confirmedDead || call == null) {
                            receipt.close(); return@post
                        }
                        call.nativeExited = true
                        call.receiptDescriptor = receipt
                        readDocument(processId, receipt) { bytes, error ->
                            try {
                                if (error != null) throw error
                                call.nativeReceipt = JSONObject(CoreFrames.utf8(checkNotNull(bytes)))
                            } catch (failure: Throwable) { call.failure = mergeFailure(call.failure, failure) }
                            finally {
                                call.receiptExited = true
                                call.exited.countDown()
                                emit(mapOf(Contract.CORE_FIELD_PROCESS_ID to processId, Contract.CORE_FIELD_REQUEST_ID to requestId,
                                    Contract.CORE_FIELD_EXITED to true))
                                retireIfDrained(call)
                            }
                        }
                    }
                }
            }
            connected.callback = callback
            val snapshot = connected.remote.handshake(Contract.CORE_IPC_VERSION, callback)
            val processId = try {
                CoreControl.check(snapshot)
                snapshot.getString(Contract.CORE_FIELD_PROCESS_ID)
                    ?: throw IOException("Core handshake is missing processId")
            } finally {
                snapshot.getParcelable<ParcelFileDescriptor>("details")?.let { descriptor ->
                    snapshot.remove("details")
                    descriptor.close()
                }
            }
            connected.processId = processId
            CoreControl.identity(snapshot, processId)
            acceptStatus(connected, connected.remote.status(identity(processId)))
            val waiters = handshakeWaiters.toList()
            handshakeWaiters.clear()
            waiters.forEach { callback -> main.post { callback(status(), null) } }
        } catch (error: Throwable) {
            communicationLost(connected.binding, error)
            if (!connected.deathLinked) {
                unbind(connected)
                if (connection === connected) connection = null
            }
            failHandshake(error)
        }
    }

    private fun failHandshake(error: Throwable) {
        if (connection == null) {
            val owner = binding
            if (owner?.bound == true) {
                try { context.unbindService(owner) } catch (close: Throwable) { if (close !== error) error.addSuppressed(close) }
                owner.bound = false
            }
            binding = null
        }
        val waiters = handshakeWaiters.toList()
        handshakeWaiters.clear()
        waiters.forEach { callback -> main.post { callback(null, error) } }
    }

    private fun mergeFailure(first: Throwable?, next: Throwable): Throwable =
        first?.also { if (it !== next) it.addSuppressed(next) } ?: next

    private fun readDocument(processId: String, descriptor: ParcelFileDescriptor, reply: (ByteArray?, Throwable?) -> Unit) {
        documentReads[descriptor] = processId
        try {
            io.execute {
                var bytes: ByteArray? = null
                var failure: Throwable? = null
                try { bytes = ParcelFileDescriptor.AutoCloseInputStream(descriptor).use(CoreDocuments::read) }
                catch (error: Throwable) { failure = error }
                finally { state.post {
                    documentReads.remove(descriptor)
                    reply(bytes, failure)
                    completeExitWhenDrained(processId)
                    main.post { changed(false) }
                } }
            }
        } catch (error: Throwable) {
            try { descriptor.close() } catch (close: Throwable) { if (close !== error) error.addSuppressed(close) }
            documentReads.remove(descriptor)
            reply(null, error)
        }
    }

    fun canAdmitSystemStart(): Boolean = session.snapshot().phase == NativeSession.Phase.STOPPED &&
        calls.values.none { it.operation != Contract.CORE_OPERATION_LOGS && !it.drained } &&
        statusValue[Contract.CORE_FIELD_PHASE] != Contract.CORE_PHASE_COMMUNICATION_LOST &&
        statusValue[Contract.CORE_FIELD_PHASE] != Contract.CORE_PHASE_STOPPING

    fun acceptRuntimeStatus(snapshot: Bundle, reply: (Throwable?) -> Unit) {
        state.post {
            val owner = connection
            val details = snapshot.getParcelable<ParcelFileDescriptor>("details")
            snapshot.remove("details")
            if (owner == null || owner.confirmedDead || snapshot.getString(Contract.CORE_FIELD_PROCESS_ID) != owner.processId) {
                details?.close()
                main.post { reply(IOException("Runtime event belongs to an old core process")) }
            } else if (details == null) main.post { reply(null) }
            else {
                val sequence = ++owner.statusSequence
                readDocument(owner.processId, details) { bytes, failure ->
                    var error = failure
                    try {
                        if (failure != null) throw failure
                        val decoded = JSONObject(CoreFrames.utf8(checkNotNull(bytes)))
                        applyStatusDetails(owner, snapshot.map(), sequence, decoded)
                    } catch (caught: Throwable) { error = caught }
                    main.post { reply(error) }
                }
            }
        }
    }

    private fun acceptStatus(owner: Connection, snapshot: Bundle, complete: (Throwable?) -> Unit = {}) {
        val details = snapshot.getParcelable<ParcelFileDescriptor>("details")
        snapshot.remove("details")
        if (connection !== owner || owner.confirmedDead) { details?.close(); complete(IOException("Core status belongs to an old connection")); return }
        if (owner.processId.isNotEmpty()) CoreControl.identity(snapshot, owner.processId)
        val value = mapOf<String, Any?>("alwaysOn" to null, "lockdown" to null) + snapshot.map() +
            if (details == null) mapOf(Contract.CORE_FIELD_ERROR to null) else emptyMap()
        val same = sameSource(statusValue, value)
        val currentRevision = (statusValue[Contract.CORE_FIELD_LISTENER_REVISION] as? Number)?.toLong() ?: 0
        val incomingRevision = (value[Contract.CORE_FIELD_LISTENER_REVISION] as? Number)?.toLong() ?: 0
        if (same && (statusValue[Contract.CORE_FIELD_PHASE] == Contract.CORE_PHASE_STOPPING &&
                value[Contract.CORE_FIELD_PHASE] != Contract.CORE_PHASE_STOPPING ||
                incomingRevision < currentRevision && value[Contract.CORE_FIELD_PHASE] != Contract.CORE_PHASE_STOPPING)) {
            details?.close(); complete(null); return
        }
        val sequence = ++owner.statusSequence
        val previous = if (same) statusValue else emptyMap()
        publish(previous + value)
        restoreInput(owner)
        if (details != null) readDocument(owner.processId, details) { bytes, failure ->
            var error = failure
            try {
                if (failure != null) throw failure
                val decoded = JSONObject(CoreFrames.utf8(checkNotNull(bytes)))
                applyStatusDetails(owner, value, sequence, decoded)
            } catch (caught: Throwable) {
                error = caught
                if (currentStatus(owner, value) && owner.statusSequence == sequence) {
                    publish(statusValue + mapOf(Contract.CORE_FIELD_ERROR to CoreErrors.json(caught).toString()))
                }
            }
            complete(error)
        } else complete(null)
        snapshot.getString("cleanupCandidates")?.let { text ->
            try {
                val paths = JSONObject(text)
                CoreDataCleanup.get(context).registerCandidates(listOf("cache", "geoip", "mmdb", "asn", "geosite").mapNotNull { paths.optStringOrNull(it) })
            } catch (error: Throwable) { emit(mapOf("event" to "cleanupCandidatesError", "error" to CoreErrors.json(error).toString())) }
        }
        val record = lifecycle.snapshot()
        if (snapshot.getString(Contract.CORE_FIELD_PHASE) == Contract.CORE_PHASE_READY &&
            record.processId == owner.processId && record.inputId == snapshot.getString(Contract.CORE_FIELD_INPUT_ID) && record.stage == "starting") {
            try { lifecycle.running(owner.processId, record.inputId!!) }
            catch (error: Throwable) { emit(mapOf("event" to "lifecycleError", "error" to CoreErrors.json(error).toString())) }
        }
        val event = snapshot.getString("event")
        if (event != null) emit(value)
        schedulePreviewIdle()
    }

    private fun applyStatusDetails(owner: Connection, captured: Map<String, Any?>, sequence: Long, decoded: JSONObject) {
        if (!currentStatus(owner, captured)) return
        val extra = mutableMapOf<String, Any?>()
        if (owner.statusSequence == sequence) extra[Contract.CORE_FIELD_ERROR] = decoded.optJSONObject(Contract.CORE_FIELD_ERROR)?.toString()
        if (statusValue[Contract.CORE_FIELD_PHASE] == Contract.CORE_PHASE_READY &&
            captured[Contract.CORE_FIELD_LISTENER_REVISION] == statusValue[Contract.CORE_FIELD_LISTENER_REVISION]) {
            decoded.optJSONArray("lanListeners")?.let { rows ->
                extra["lanListeners"] = (0 until rows.length()).map { rows.getJSONObject(it).objectMap() }
            }
            if (owner.statusSequence == sequence && decoded.has("applicationAccess")) {
                extra["applicationAccess"] = decoded.optJSONObject("applicationAccess")?.objectMap()
            }
        }
        if (extra.isNotEmpty()) publish(statusValue + extra)
    }

    private fun communicationLost(owner: Binding, error: Throwable) {
        if (binding !== owner) return
        publish(statusValue + mapOf(Contract.CORE_FIELD_PHASE to Contract.CORE_PHASE_COMMUNICATION_LOST,
            Contract.CORE_FIELD_ERROR to CoreErrors.json(error, Contract.CORE_ERROR_COMMUNICATION_LOST).toString()))
        emit(mapOf(Contract.CORE_FIELD_PROCESS_ID to connection?.processId,
            Contract.CORE_FIELD_PHASE to Contract.CORE_PHASE_COMMUNICATION_LOST,
            Contract.CORE_FIELD_ERROR to CoreErrors.json(error, Contract.CORE_ERROR_COMMUNICATION_LOST).toString()))
        failHandshake(error)
        // Keep waiting for the registered DeathRecipient callback; disconnection does not release requests, locks, or exit waiters.
    }

    private fun died(owner: Connection) {
        if (connection !== owner || !owner.deathLinked || owner.confirmedDead) return
        owner.confirmedDead = true
        val processId = owner.processId
        val failure = CoreTransportException(Contract.CORE_ERROR_PROCESS_EXITED, "Core has exited")
        calls.values.filter { it.processId == processId }.forEach { call ->
            call.failure = mergeFailure(call.failure, failure)
            call.nativeExited = true
            if (call.receiptDescriptor == null) call.receiptExited = true
            call.exited.countDown()
            try { call.input.close() } catch (_: Exception) { }
            try { call.output.close() } catch (_: Exception) { }
            if (!call.reading) call.ioExited = true
            retireIfDrained(call)
        }
        documentReads.forEach { (descriptor, process) -> if (process == processId) try { descriptor.close() } catch (error: Throwable) { failure.addSuppressed(error) } }
        try { lifecycle.died(processId) }
        catch (error: Throwable) { failure.addSuppressed(error) }
        unbind(owner)
        connection = null
        publish(statusValue + mapOf(Contract.CORE_FIELD_PHASE to Contract.CORE_PHASE_EXITED, "vpnRunning" to false,
            "lanRunning" to false, "recoveryRequired" to lifecycle.snapshot().recoveryRequired))
        emit(mapOf(Contract.CORE_FIELD_PROCESS_ID to processId, Contract.CORE_FIELD_PHASE to Contract.CORE_PHASE_EXITED,
            Contract.CORE_FIELD_EXITED to true, "recoveryRequired" to lifecycle.snapshot().recoveryRequired))
        completeExitWhenDrained(processId)
    }

    private fun releaseAutoCreate(owner: Connection) {
        if (owner.binding.bound) {
            try { context.unbindService(owner.binding) }
            catch (error: Throwable) {
                android.util.Log.w("CoreClient", "Failed to drop BIND_AUTO_CREATE while waiting for core death", error)
            }
            owner.binding.bound = false
        }
    }

    private fun unbind(owner: Connection) {
        if (owner.deathLinked) runCatching { owner.binder.unlinkToDeath(owner.death, 0) }
        releaseAutoCreate(owner)
        if (binding === owner.binding) binding = null
    }

    private fun publish(value: Map<String, Any?>) {
        val record = lifecycle.snapshot()
        val retiring = record.processId == value[Contract.CORE_FIELD_PROCESS_ID] && record.stage == Contract.CORE_PHASE_STOPPING
        val phaseProjected = if (retiring && value[Contract.CORE_FIELD_PHASE] in setOf(
                Contract.CORE_PHASE_CONNECTED, Contract.CORE_PHASE_LOADING, Contract.CORE_PHASE_READY))
            value + (Contract.CORE_FIELD_PHASE to Contract.CORE_PHASE_STOPPING) else value
        val projected = if (phaseProjected[Contract.CORE_FIELD_PHASE] in setOf(Contract.CORE_PHASE_STOPPING, Contract.CORE_PHASE_EXITED))
            phaseProjected + mapOf("lanListeners" to emptyList<Map<String, Any?>>(), "applicationAccess" to null) else phaseProjected
        val statusChanged = statusValue != projected
        statusValue = projected
        session.project(projected)
        main.post { changed(statusChanged) }
    }
    private fun emit(value: Map<String, Any?>) { main.post { onEvent(value) } }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            Contract.CORE_CHANNEL_HANDSHAKE -> handshake { value, error -> if (error == null) result.success(value) else failed(result, error) }
            Contract.CORE_CHANNEL_STATUS -> result.success(status())
            Contract.CORE_CHANNEL_SUBMIT -> submit(call.arguments as? Map<*, *> ?: emptyMap<Any, Any>(), result)
            Contract.CORE_CHANNEL_READ -> read(call.argument<String>(Contract.CORE_FIELD_PROCESS_ID).orEmpty(),
                call.argument<Number>(Contract.CORE_FIELD_REQUEST_ID)?.toLong() ?: 0, result)
            Contract.CORE_CHANNEL_CANCEL -> cancel(call.argument<String>(Contract.CORE_FIELD_PROCESS_ID).orEmpty(),
                call.argument<Number>(Contract.CORE_FIELD_REQUEST_ID)?.toLong() ?: 0, result)
            Contract.CORE_CHANNEL_EXIT -> {
                val admittedAt = call.argument<Number>(Contract.CORE_FIELD_ADMITTED_AT)?.toLong() ?: -1
                val deadline = call.argument<Number>(Contract.CORE_FIELD_DEADLINE)?.toLong() ?: -1
                exit(call.argument<String>(Contract.CORE_FIELD_PROCESS_ID).orEmpty(), admittedAt, deadline,
                    call.argument<String>("reason") ?: "stop") { error -> if (error == null) result.success(mapOf("exited" to true)) else failed(result, error) }
            }
            Contract.CORE_CHANNEL_PUBLISH_RUN_INPUT -> publishRunInput(call, result)
            Contract.CORE_CHANNEL_READ_RUN_INPUT_RECORD -> readRunInputRecord(call, result)
            else -> result.notImplemented()
        }
    }

    private fun submit(arguments: Map<*, *>, result: MethodChannel.Result) {
        val operation = (arguments[Contract.CORE_FIELD_OPERATION] as? Number)?.toInt()
        val captured = arguments["identity"] as? Map<*, *> ?: emptyMap<Any, Any>()
        val inputId = arguments[Contract.CORE_FIELD_INPUT_ID] as? String ?: captured[Contract.CORE_FIELD_INPUT_ID] as? String
        val body = (arguments["arguments"] as? Map<*, *>)?.entries?.associate { it.key.toString() to it.value }.orEmpty()
        state.post {
            val owner = connection
            try {
                check(owner != null && !owner.confirmedDead && captured[Contract.CORE_FIELD_PROCESS_ID] == owner.processId) { "Request does not belong to the current core process" }
                require(operation != null)
                val record = lifecycle.snapshot()
                if (record.processId == owner.processId && record.stage == Contract.CORE_PHASE_STOPPING &&
                    operation != Contract.CORE_OPERATION_CANCEL) {
                    throw CoreTransportException(Contract.CORE_ERROR_IDENTITY_MISMATCH, "A cancelled or exiting core context no longer admits application requests")
                }
                require((captured[Contract.CORE_FIELD_PROTOCOL] as? Number)?.toInt() == Contract.CORE_IPC_VERSION) { "Core protocol mismatch" }
                require((captured[Contract.CORE_FIELD_NETWORK_REVISION] as? Number)?.toLong() == (statusValue[Contract.CORE_FIELD_NETWORK_REVISION] as? Number)?.toLong()) { "Core Network revision mismatch" }
                val generation = (captured[Contract.CORE_FIELD_GENERATION] as? Number)?.toLong() ?: 0L
                val composition = captured[Contract.CORE_FIELD_COMPOSITION] as? String
                val request = JSONObject().put("arguments", JSONObject(body.filterKeys { it != "parts" }))
                    .put(Contract.CORE_FIELD_OPERATION, operation).put(Contract.CORE_FIELD_PROTOCOL, Contract.CORE_IPC_VERSION)
                    .put(Contract.CORE_FIELD_PROCESS_ID, owner.processId).put(Contract.CORE_FIELD_REQUEST_ID, 0L)
                    .put(Contract.CORE_FIELD_GENERATION, generation).put(Contract.CORE_FIELD_INPUT_ID, inputId.orEmpty())
                    .put(Contract.CORE_FIELD_NETWORK_REVISION, (captured[Contract.CORE_FIELD_NETWORK_REVISION] as? Number)?.toLong() ?: 0L)
                val parts = makeParts(operation, inputId, request, arguments)
                CoreParts.validate(parts)
                if (operation == Contract.CORE_OPERATION_PREPARE) {
                    CoreDataCleanup.get(context).requireReady()
                    lifecycle.starting(owner.processId, checkNotNull(inputId), body["userRecovery"] == true || body["explicitStart"] == true)
                    publish(statusValue + mapOf(Contract.CORE_FIELD_INPUT_ID to inputId,
                        Contract.CORE_FIELD_GENERATION to generation,
                        Contract.CORE_FIELD_COMPOSITION to parts[Contract.CORE_PART_OPTIONS]?.let { JSONObject(CoreFrames.utf8(it)).optString(Contract.CORE_FIELD_COMPOSITION) },
                        "configId" to request.getJSONObject("arguments").optStringOrNull("configId"), "revision" to request.getJSONObject("arguments").optInt("revision"),
                        "purpose" to request.getJSONObject("arguments").optString("purpose"), "vpnIntent" to request.getJSONObject("arguments").optBoolean("vpnIntent"),
                        "lanIntent" to request.getJSONObject("arguments").optBoolean("lanIntent")))
                    if (request.getJSONObject("arguments").optBoolean("lanIntent")) {
                        val intent = Intent(context, CoreService::class.java).setAction(CoreService.ACTION_LAN_FOREGROUND)
                        if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
                    }
                }
                val input = ParcelFileDescriptor.createPipe()
                val output = ParcelFileDescriptor.createPipe()
                val control = identity(owner.processId).apply {
                    putInt(Contract.CORE_FIELD_OPERATION, operation)
                    putLong(Contract.CORE_FIELD_GENERATION, generation); putString(Contract.CORE_FIELD_INPUT_ID, inputId)
                    putLong(Contract.CORE_FIELD_NETWORK_REVISION, request.optLong(Contract.CORE_FIELD_NETWORK_REVISION))
                }
                try {
                    val accepted = input[0].use { source -> output[1].use { target -> owner.remote.submit(control, source, target) } }
                    CoreControl.check(accepted)
                    val id = accepted.getLong(Contract.CORE_FIELD_REQUEST_ID)
                    if (!accepted.getBoolean(Contract.CORE_FIELD_ACCEPTED) || id <= 0L) throw IOException("Core did not admit the request")
                    request.put(Contract.CORE_FIELD_REQUEST_ID, id)
                    val acceptedParts = parts + (Contract.CORE_PART_REQUEST to request.toString().toByteArray(Charsets.UTF_8))
                    val call = Call(owner.processId, id, operation, inputId,
                        composition, generation, request.optLong(Contract.CORE_FIELD_NETWORK_REVISION), input[1], output[0], arguments["owner"] as? String)
                    check(calls.putIfAbsent(owner.processId to id, call) == null) { "Duplicate core requestId" }
                    io.execute {
                        try { ParcelFileDescriptor.AutoCloseOutputStream(input[1]).use { CoreParts.write(it, acceptedParts) } }
                        catch (error: Throwable) { call.failure = error; state.post { emitCallFailure(call, error) } }
                        finally { call.writeExited = true; state.post { retireIfDrained(call); completeExitWhenDrained(call.processId) } }
                    }
                    main.post { result.success(mapOf(Contract.CORE_FIELD_ACCEPTED to true,
                        Contract.CORE_FIELD_REQUEST_ID to id, Contract.CORE_FIELD_PROCESS_ID to owner.processId)) }
                } catch (error: Throwable) {
                    input.forEach { runCatching { it.close() } }; output.forEach { runCatching { it.close() } }
                    throw error
                }
            } catch (error: Throwable) { main.post { failed(result, error) } }
        }
    }

    private fun makeParts(operation: Int, inputId: String?, request: JSONObject, arguments: Map<*, *>): Map<String, ByteArray> {
        val parts = linkedMapOf<String, ByteArray>()
        val payload = request.getJSONObject("arguments")
        if (operation == Contract.CORE_OPERATION_PREPARE || operation == Contract.CORE_OPERATION_COMPOSE) {
            if (inputId != null) {
                val file = AppFiles.runRecord(context, inputId)
                val raw = JSONObject(CoreFrames.utf8(CorePrivateFiles.read(file, AppFiles.MAX_RUN_RECORD_BYTES)
                    ?: throw IOException("Preparation input record does not exist")))
                val input = CoreInput.read(raw, raw.getString("id"), CoreInput.integerRevision(raw.get("revision")), raw.optStringOrNull("mode"))
                parts[Contract.CORE_PART_CONFIG] = input.body
                parts[Contract.CORE_PART_OVERRIDES] = input.overrides
                parts[Contract.CORE_PART_OPTIONS] = input.preparationOptions(payload.optString("purpose", Contract.CORE_PURPOSE_PREVIEW),
                    request.optLong(Contract.CORE_FIELD_GENERATION).coerceAtLeast(1), JSONObject())
                payload.put("configId", input.id).put("revision", input.revision).put("mode", input.mode ?: JSONObject.NULL)
                    .put("access", input.access).put("packages", JSONArray(input.packages))
            } else {
                val supplied = arguments["parts"] as? Map<*, *> ?: (arguments["arguments"] as? Map<*, *>)?.get("parts") as? Map<*, *> ?: payload.optJSONObject("parts")?.let { json -> json.keys().asSequence().associateWith { json.get(it) } }.orEmpty()
                supplied.forEach { (key, value) ->
                    val bytes = when (value) { is ByteArray -> value; is String -> value.toByteArray(Charsets.UTF_8); else -> throw IllegalArgumentException("Core input part is not raw bytes") }
                    parts[key.toString()] = bytes
                }
            }
        }
        if (operation == Contract.CORE_OPERATION_INITIALIZE_TRUST) {
            parts[Contract.CORE_PART_TRUST] = (arguments["trust"] as? ByteArray) ?: byteArrayOf()
        }
        parts[Contract.CORE_PART_REQUEST] = request.toString().toByteArray(Charsets.UTF_8)
        return parts
    }

    private fun awaitActualExit(call: Call) {
        var interrupted = false
        try { while (true) try { call.exited.await(); return } catch (_: InterruptedException) { interrupted = true } }
        finally { if (interrupted) Thread.currentThread().interrupt() }
    }

    private fun read(processId: String, requestId: Long, result: MethodChannel.Result) {
        val call = calls[processId to requestId]
        if (call == null) { failed(result, CoreTransportException(Contract.CORE_ERROR_IDENTITY_MISMATCH, "Core request does not exist or has finished")); return }
        synchronized(call) {
            if (call.reading) { failed(result, IllegalStateException("A read is already in progress for this core request")); return }
            call.reading = true
        }
        io.execute {
            try {
                call.failure?.let { throw it }
                val frame = call.reader.read()
                if (frame.kind == Contract.CORE_IPC_FRAME_TERMINAL) {
                    call.terminal = true
                    // Go may write the terminal frame before returning from JNI; wait for the separate exit receipt first.
                    awaitActualExit(call)
                    call.failure?.let { throw it }
                    call.output.close()
                }
                main.post {
                    synchronized(call) { call.reading = false }
                    result.success(mapOf("kind" to frame.kind, "payload" to frame.payload) +
                        if (frame.kind == Contract.CORE_IPC_FRAME_TERMINAL) mapOf("nativeReceipt" to call.nativeReceipt?.objectMap()) else emptyMap())
                }
            } catch (error: Throwable) {
                var failure = mergeFailure(call.failure, error)
                try { call.output.close() } catch (close: Throwable) { failure = mergeFailure(failure, close) }
                // An interrupted result FD does not mean JNI has returned; wait for the receipt FD to finish or the matching DeathRecipient.
                awaitActualExit(call)
                failure = call.failure?.let { mergeFailure(it, failure) } ?: failure
                val actual = call.nativeReceipt?.let { CoreNativeCallException(it.toString().toByteArray(Charsets.UTF_8), failure) } ?: failure
                call.ioExited = true
                main.post { synchronized(call) { call.reading = false }; failed(result, actual) }
            } finally {
                if (call.terminal) call.ioExited = true
                state.post { retireIfDrained(call); completeExitWhenDrained(processId) }
            }
        }
    }

    private fun cancel(processId: String, requestId: Long, result: MethodChannel.Result) {
        state.post {
            val owner = connection
            val target = calls[processId to requestId]
            if (owner == null || owner.processId != processId || owner.confirmedDead || target == null) {
                main.post { failed(result, CoreTransportException(Contract.CORE_ERROR_IDENTITY_MISMATCH, "Cancel request belongs to an old core process or call")) }
                return@post
            }
            if (target.operation == Contract.CORE_OPERATION_PREPARE) {
                try {
                    // Revoke authority for further application requests; keep the original call, receipt, and lease until actual exit.
                    val record = lifecycle.snapshot()
                    if (record.processId != processId || record.stage != Contract.CORE_PHASE_STOPPING)
                        lifecycle.requestExit(processId, "reconnect")
                    publish(statusValue + (Contract.CORE_FIELD_PHASE to Contract.CORE_PHASE_STOPPING))
                } catch (error: Throwable) {
                    communicationLost(owner.binding, error)
                    main.post { failed(result, error) }
                    return@post
                }
            }
            val identity = mapOf(Contract.CORE_FIELD_PROTOCOL to Contract.CORE_IPC_VERSION,
                Contract.CORE_FIELD_PROCESS_ID to processId, Contract.CORE_FIELD_INPUT_ID to target.inputId,
                Contract.CORE_FIELD_GENERATION to target.generation, Contract.CORE_FIELD_NETWORK_REVISION to target.networkRevision)
            submit(mapOf("operation" to Contract.CORE_OPERATION_CANCEL, "identity" to identity,
                "arguments" to mapOf("targetRequestId" to requestId)), object : MethodChannel.Result {
                override fun success(admission: Any?) {
                    val id = ((admission as? Map<*, *>)?.get(Contract.CORE_FIELD_REQUEST_ID) as? Number)?.toLong()
                    if (id == null) { failed(result, IOException("CANCEL was not admitted")); return }
                    val bytes = java.io.ByteArrayOutputStream()
                    var started: Boolean? = null
                    fun cancellationFailure(code: String, message: String?, details: Any?) {
                        val actual = if (started == null) details else try {
                            JSONObject(details as String).put(Contract.CORE_FIELD_STARTED, started).toString()
                        } catch (_: Exception) {
                            JSONObject().put(Contract.CORE_FIELD_STARTED, started).put(Contract.CORE_FIELD_ERROR, details).toString()
                        }
                        result.error(code, message, actual)
                    }
                    fun next() {
                        read(processId, id, object : MethodChannel.Result {
                            override fun success(value: Any?) {
                                try {
                                    val frame = value as Map<*, *>
                                    when ((frame["kind"] as Number).toInt()) {
                                        Contract.CORE_IPC_FRAME_DATA -> { bytes.write(frame["payload"] as ByteArray); next() }
                                        Contract.CORE_IPC_FRAME_METADATA -> {
                                            val metadata = JSONObject(CoreFrames.utf8(frame["payload"] as ByteArray))
                                            if (metadata.has(Contract.CORE_FIELD_STARTED)) started = metadata.getBoolean(Contract.CORE_FIELD_STARTED)
                                            next()
                                        }
                                        Contract.CORE_IPC_FRAME_TERMINAL -> {
                                            val terminal = JSONObject(CoreFrames.utf8(frame["payload"] as ByteArray))
                                            val native = frame["nativeReceipt"] as? Map<*, *>
                                            val nativeError = native?.get("error")
                                            if (!terminal.optBoolean("complete") || terminal.optJSONObject("error") != null || nativeError != null) {
                                                val cause = IOException(terminal.toString())
                                                throw if (native == null) cause else CoreNativeCallException(JSONObject(native).toString().toByteArray(Charsets.UTF_8), cause)
                                            }
                                            val actual = JSONObject(CoreFrames.utf8(bytes.toByteArray())).objectMap()
                                            result.success(actual + if (started == null) emptyMap() else mapOf(Contract.CORE_FIELD_STARTED to started))
                                        }
                                        else -> throw CoreTransportException(Contract.CORE_ERROR_TRANSPORT_INTERRUPTED, "CANCEL returned a non-DATA frame")
                                    }
                                } catch (error: Throwable) {
                                    cancellationFailure((error as? CoreTransportException)?.code ?: Contract.CORE_ERROR_CALL_FAILED,
                                        error.message, CoreErrors.json(error).toString())
                                }
                            }
                            override fun error(code: String, message: String?, details: Any?) = cancellationFailure(code, message, details)
                            override fun notImplemented() = result.notImplemented()
                        })
                    }
                    next()
                }
                override fun error(code: String, message: String?, details: Any?) = result.error(code, message, details)
                override fun notImplemented() = result.notImplemented()
            })
        }
    }

    fun cancelOwner(owner: String) {
        val processId = statusValue[Contract.CORE_FIELD_PROCESS_ID] as? String ?: return
        calls.values.filter { it.processId == processId && it.owner == owner }.forEach { call ->
            cancel(processId, call.id, object : MethodChannel.Result {
                override fun success(result: Any?) = Unit
                override fun error(code: String, message: String?, details: Any?) = Unit
                override fun notImplemented() = Unit
            })
        }
    }

    fun exit(processId: String, admittedAt: Long, deadline: Long, reason: String, reply: (Throwable?) -> Unit) {
        state.post {
            try {
                require(admittedAt >= 0 && deadline >= admittedAt && deadline - admittedAt <= Contract.OPERATION_BACKUP_TIMEOUT_MS)
            } catch (error: Throwable) {
                main.post { reply(error) }
                return@post
            }
            val owner = connection
            if (owner == null) {
                val gate = CoreResourceGate.forApplication(context).tryAcquire()
                if (gate == null) {
                    if (SystemClock.elapsedRealtime() >= deadline) main.post { reply(IOException("Core exit is unconfirmed")) }
                    else handshake { snapshot, error ->
                        val actualId = snapshot?.get(Contract.CORE_FIELD_PROCESS_ID) as? String
                        if (error != null || actualId == null) reply(error ?: IOException("Core identity is unconfirmed"))
                        else if (processId.isNotEmpty() && processId != actualId) reply(IOException("Exit request belongs to an old core process"))
                        else exit(actualId, admittedAt, deadline, reason, reply)
                    }
                } else {
                    gate.close()
                    awaitExitDeadline(processId, deadline, reply)
                    completeExitWhenDrained(processId)
                }
                return@post
            }
            if (owner.processId != processId) { main.post { reply(IOException("Exit request belongs to an old core process")) }; return@post }
            try {
                if (lifecycle.snapshot().processId == processId) lifecycle.requestExit(processId, reason)
                publish(statusValue + (Contract.CORE_FIELD_PHASE to Contract.CORE_PHASE_STOPPING))
                owner.recoverySource = null
                awaitExitDeadline(processId, deadline, reply)
                val request = identity(processId).apply {
                    putLong(Contract.CORE_FIELD_ADMITTED_AT, admittedAt); putLong(Contract.CORE_FIELD_DEADLINE, deadline); putString("reason", reason)
                }
                try {
                    owner.remote.requestExit(request)
                } finally {
                    // Keep DeathRecipient linked, but drop BIND_AUTO_CREATE so Android cannot resurrect :core after kill.
                    releaseAutoCreate(owner)
                }
            } catch (error: Throwable) {
                communicationLost(owner.binding, error)
                if (error !is DeadObjectException || !owner.deathLinked) {
                    exitWaiters.remove(reply)
                    main.post { reply(error) }
                }
            }
        }
    }

    private fun awaitExitDeadline(processId: String, deadline: Long, reply: (Throwable?) -> Unit) {
        exitWaiters[reply] = processId
        state.postDelayed({
            if (exitWaiters.remove(reply) != null) {
                val error = IOException("The exit request's original admission deadline has expired; the core process or local FD I/O has not finished")
                main.post { reply(error) }
            }
        }, (deadline - SystemClock.elapsedRealtime()).coerceAtLeast(0L) + Contract.OPERATION_UI_GRACE_MS)
    }

    private fun retireIfDrained(call: Call) {
        if (!call.drained) return
        if (calls.remove(call.processId to call.id, call) && call.operation != Contract.CORE_OPERATION_LOGS)
            hiddenAt = SystemClock.elapsedRealtime()
        completeExitWhenDrained(call.processId)
        main.post { changed(false) }
        schedulePreviewIdle()
    }
    private fun completeExitWhenDrained(processId: String) {
        val waiters = exitWaiters.filter { (_, target) ->
            (target.isEmpty() || target == processId) &&
                connection?.let { target.isEmpty() || it.processId == target } != true &&
                documentReads.values.none { target.isEmpty() || it == target } &&
                calls.values.none { (target.isEmpty() || it.processId == target) && !it.drained }
        }.keys.toList()
        waiters.forEach { receiver ->
            exitWaiters.remove(receiver)
            main.post { receiver(null) }
        }
    }
    private fun emitCallFailure(call: Call, error: Throwable) = emit(mapOf(Contract.CORE_FIELD_PROCESS_ID to call.processId,
        Contract.CORE_FIELD_REQUEST_ID to call.id, Contract.CORE_FIELD_ERROR to CoreErrors.json(error).toString()))

    private fun publishRunInput(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        val id = call.argument<String>(Contract.CORE_FIELD_INPUT_ID)
        io.execute {
            try {
                require(path != null && id != null)
                val source = File(path)
                check(source.parentFile?.absoluteFile?.normalize() == AppFiles.work(context).absoluteFile.normalize() &&
                    (source.name.startsWith("run-input-") || source.name == AppFiles.systemInput(context).name)) { "Invalid preparation input staging path" }
                val bytes = CorePrivateFiles.read(source, AppFiles.MAX_RUN_RECORD_BYTES) ?: throw IOException("Preparation input staging file does not exist")
                val raw = JSONObject(CoreFrames.utf8(bytes))
                CoreInput.read(raw, raw.getString("id"), CoreInput.integerRevision(raw.get("revision")), raw.optStringOrNull("mode"))
                val target = AppFiles.runRecord(context, id)
                check(!target.exists()) { "Immutable preparation record already exists" }
                var publicationError: Throwable? = null
                try { CorePrivateFiles.write(target, bytes) }
                catch (error: CoreRecordPublicationException) { publicationError = error }
                val publication = mapOf("saved" to true, "durable" to (publicationError == null), "path" to target.path,
                    Contract.CORE_FIELD_INPUT_ID to id, "error" to publicationError?.let { CoreErrors.json(it).objectMap() })
                main.post { result.success(publication) }
            } catch (error: Throwable) { main.post { failed(result, error) } }
        }
    }

    private fun readRunInputRecord(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>(Contract.CORE_FIELD_INPUT_ID)
        io.execute {
            try {
                require(id != null)
                val file = AppFiles.runRecord(context, id)
                if (CorePrivateFiles.read(file, AppFiles.MAX_RUN_RECORD_BYTES) == null) throw IOException("Actual preparation input record does not exist")
                CorePrivateFiles.sync(file.parentFile!!)
                main.post { result.success(mapOf("saved" to true, "durable" to true, "path" to file.path, Contract.CORE_FIELD_INPUT_ID to id)) }
            } catch (error: Throwable) { main.post { failed(result, error) } }
        }
    }

    private fun identity(processId: String) = Bundle().apply {
        putInt(Contract.CORE_FIELD_PROTOCOL, Contract.CORE_IPC_VERSION); putString(Contract.CORE_FIELD_PROCESS_ID, processId)
        putString("language", AppStrings.language)
    }
    private fun failed(result: MethodChannel.Result, error: Throwable) = result.error(
        (error as? CoreTransportException)?.code ?: Contract.CORE_ERROR_CALL_FAILED, error.message, CoreErrors.json(error).toString())

    private fun refreshRecoveryNotice() {
        val manager = context.getSystemService(NotificationManager::class.java)
        if (manager.activeNotifications.any { it.id == 5 && it.tag == null }) publishRecoveryNotice()
    }

    fun publishRecoveryNotice() {
        val manager = context.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(NotificationChannel("core-recovery", AppStrings.get(R.string.core_recovery_channel), NotificationManager.IMPORTANCE_DEFAULT))
        val open = PendingIntent.getActivity(context, 0, Intent(context, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        manager.notify(5, NotificationCompat.Builder(context, "core-recovery").setSmallIcon(R.drawable.ic_vpn_notification)
            .setContentTitle(AppStrings.get(R.string.core_recovery_title)).setContentText(AppStrings.get(R.string.core_recovery_body))
            .setContentIntent(open).setAutoCancel(true).setOnlyAlertOnce(true).build())
    }

    inner class View {
        val worker get() = io
        fun snapshot(value: Map<String, Any?> = statusValue): CoreHost.Snapshot {
            val raw = value[Contract.CORE_FIELD_PHASE]
            return CoreHost.Snapshot((value[Contract.CORE_FIELD_GENERATION] as? Number)?.toLong() ?: 0,
                when (raw) { Contract.CORE_PHASE_LOADING -> CoreHost.Phase.LOADING; Contract.CORE_PHASE_READY -> CoreHost.Phase.READY
                    Contract.CORE_PHASE_STOPPING -> CoreHost.Phase.RELEASING; Contract.CORE_PHASE_COMMUNICATION_LOST -> CoreHost.Phase.FAILED; else -> CoreHost.Phase.EMPTY },
                when (value["purpose"]) { Contract.CORE_PURPOSE_PREVIEW -> CoreHost.Purpose.PREVIEW; Contract.CORE_PURPOSE_RUNNING -> CoreHost.Purpose.RUNNING; else -> null },
                value["configId"] as? String, (value["revision"] as? Number)?.toInt(),
                null, value[Contract.CORE_FIELD_COMPOSITION] as? String, null,
                value[Contract.CORE_FIELD_PROCESS_ID] as? String, value[Contract.CORE_FIELD_INPUT_ID] as? String)
        }
        fun current(generation: Long) = snapshot().let { it.generation == generation && it.phase == CoreHost.Phase.READY }
        fun setVisible(value: Boolean) { state.post {
            if (visible && !value) {
                hiddenAt = SystemClock.elapsedRealtime()
                val current = connection
                if (current != null && statusValue[Contract.CORE_FIELD_PHASE] == Contract.CORE_PHASE_READY &&
                    statusValue["purpose"] == Contract.CORE_PURPOSE_PREVIEW) {
                    try {
                        acceptStatus(current, current.remote.status(identity(current.processId).apply {
                            putBoolean(CoreService.PREVIEW_BACKGROUND, true)
                        }))
                    } catch (error: Throwable) { communicationLost(current.binding, error) }
                }
            }
            visible = value
            schedulePreviewIdle()
        } }
        fun setOperationBusy(value: Boolean) { state.post {
            if (operationBusy && !value) hiddenAt = SystemClock.elapsedRealtime()
            operationBusy = value
            schedulePreviewIdle()
        } }
        fun applicationAccess(generation: Long): Map<String, Any?>? =
            if (current(generation)) statusValue["applicationAccess"] as? Map<String, Any?> else null
    }
    private fun schedulePreviewIdle() {
        state.removeCallbacks(previewIdle)
        if (visible || operationBusy || calls.values.any { it.operation != Contract.CORE_OPERATION_LOGS && !it.drained } ||
            statusValue[Contract.CORE_FIELD_PHASE] != Contract.CORE_PHASE_READY ||
            statusValue["purpose"] != Contract.CORE_PURPOSE_PREVIEW || exitWaiters.isNotEmpty()) return
        state.postDelayed(previewIdle, (hiddenAt + 30_000 - SystemClock.elapsedRealtime()).coerceAtLeast(0))
    }
    private fun releaseIdlePreview() {
        if (visible || operationBusy || calls.values.any { it.operation != Contract.CORE_OPERATION_LOGS && !it.drained } ||
            statusValue[Contract.CORE_FIELD_PHASE] != Contract.CORE_PHASE_READY ||
            statusValue["purpose"] != Contract.CORE_PURPOSE_PREVIEW || exitWaiters.isNotEmpty()) return
        val processId = statusValue[Contract.CORE_FIELD_PROCESS_ID] as? String ?: return
        val admitted = SystemClock.elapsedRealtime()
        exit(processId, admitted, admitted + Contract.OPERATION_ORDINARY_TIMEOUT_MS, "previewExpired") { }
    }

    companion object {
        val session = NativeSession()
        @Volatile private var instance: CoreClient? = null
        fun get(context: Context): CoreClient = instance ?: synchronized(this) {
            instance ?: CoreClient(context.applicationContext).also { instance = it }
        }
        fun installed(): CoreClient = checkNotNull(instance) { "The core connection in the default process is not installed" }
    }
}

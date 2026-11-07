package io.github.monadboxlab.clashpseudo.debug

import android.app.Service
import android.content.ComponentName
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.ServiceConnection
import android.os.Binder
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.Process
import android.os.SystemClock
import io.github.monadboxlab.clashpseudo.app.AppProcess
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.nativecore.NativeCore
import io.github.monadboxlab.clashpseudo.nativecore.CoreErrors
import io.github.monadboxlab.clashpseudo.nativecore.CoreFrames
import io.github.monadboxlab.clashpseudo.nativecore.CoreParts
import io.github.monadboxlab.clashpseudo.nativecore.CoreProcessExit
import io.github.monadboxlab.clashpseudo.nativecore.CoreProcessResources
import io.github.monadboxlab.clashpseudo.nativecore.CoreService
import io.github.monadboxlab.clashpseudo.nativecore.ipc.ICoreCallback
import io.github.monadboxlab.clashpseudo.nativecore.ipc.ICoreService
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import org.json.JSONObject
import android.system.Os
import android.system.OsConstants
import io.github.monadboxlab.clashpseudo.storage.AppFiles
import java.io.File
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Fixed debug-only fixture; does not accept paths, reflection targets, code, or application operations. */
class CoreFixtureService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newCachedThreadPool { Thread(it, "core-fixture-io") }
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "core-fixture") }
    private val ready = CountDownLatch(1)
    private val submitted = AtomicBoolean()
    private val active = AtomicBoolean()
    private var remote: ICoreService? = null
    private var identity: Bundle? = null
    private var bound = false
    private var retiredService: PseudoVpnService? = null
    private var exitFailure: Throwable? = null
    private val exitSubmissions = java.util.concurrent.atomic.AtomicInteger()
    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            remote = ICoreService.Stub.asInterface(binder)
            identity = remote!!.handshake(Contract.CORE_IPC_VERSION, object : ICoreCallback.Stub() {
                @Suppress("DEPRECATION")
                override fun onStatus(status: Bundle) {
                    status.getParcelable<ParcelFileDescriptor>("details")?.let {
                        drainDocument(ParcelFileDescriptor.dup(it.fileDescriptor))
                    }
                }
                override fun onExited(processId: String, requestId: Long, receipt: ParcelFileDescriptor) {
                    drainDocument(ParcelFileDescriptor.dup(receipt.fileDescriptor))
                }
            })
            ready.countDown()
        }
        override fun onServiceDisconnected(name: ComponentName) { remote = null }
    }
    private val binder = object : ICoreFixture.Stub() {
        override fun handshake(protocol: Int): Bundle {
            sameUid()
            require(protocol == Contract.CORE_IPC_VERSION)
            check(ready.await(10, TimeUnit.SECONDS)) { "Fixture did not acquire CoreService" }
            return Bundle(checkNotNull(identity)).apply { putBoolean("nativeFixture", true) }
        }

        override fun execute(scene: Int, input: ParcelFileDescriptor, output: ParcelFileDescriptor): Bundle {
            sameUid()
            require(scene in CoreFixtureContract.TRUST..CoreFixtureContract.TUN_HANDOFF_FAILURE)
            check(submitted.compareAndSet(false, true)) { "Each fixture process runs only one native scenario" }
            check(ready.await(10, TimeUnit.SECONDS))
            val id = checkNotNull(CoreService.instance).allocateRequestId()
            active.set(true)
            try {
                worker.execute {
                    try {
                        val parts = ParcelFileDescriptor.AutoCloseInputStream(input).use(CoreParts::read)
                        val arguments = JSONObject(CoreFrames.utf8(parts.getValue(Contract.CORE_PART_REQUEST)))
                        require(arguments.optString("home").isEmpty() && !arguments.has("path")) { "Fixture does not accept caller-supplied paths" }
                        val value = CoreFixtureNativeRun(this@CoreFixtureService,
                            checkNotNull(identity!!.getString(Contract.CORE_FIELD_PROCESS_ID)),
                            { checkNotNull(CoreService.instance).allocateRequestId() }, io, scene, arguments,
                            parts[Contract.CORE_PART_CONFIG]).run()
                        ParcelFileDescriptor.AutoCloseOutputStream(output).use { target ->
                            val bytes = value.toString().toByteArray(Charsets.UTF_8)
                            require(bytes.size <= Contract.CORE_IPC_QUEUE_BYTES)
                            var offset = 0
                            while (offset < bytes.size) {
                                val end = (offset + Contract.CORE_IPC_FRAME_BYTES).coerceAtMost(bytes.size)
                                CoreFrames.write(target, CoreFrames.Frame(Contract.CORE_IPC_FRAME_DATA, bytes.copyOfRange(offset, end)))
                                offset = end
                            }
                            CoreFrames.write(target, CoreFrames.Frame(Contract.CORE_IPC_FRAME_TERMINAL,
                                JSONObject().put("complete", true).put("exited", true).toString().toByteArray()))
                        }
                    } catch (error: Throwable) {
                        try {
                            ParcelFileDescriptor.AutoCloseOutputStream(output).use { target ->
                                CoreFrames.write(target, CoreFrames.Frame(Contract.CORE_IPC_FRAME_TERMINAL,
                                    JSONObject().put("complete", false).put("exited", true)
                                        .put("error", CoreErrors.json(error)).toString().toByteArray(Charsets.UTF_8)))
                            }
                        } catch (close: Throwable) { if (error !== close) error.addSuppressed(close) }
                    } finally {
                        input.close(); output.close(); active.set(false)
                    }
                }
            } catch (error: Throwable) {
                active.set(false); input.close(); output.close(); throw error
            }
            return Bundle().apply { putBoolean("accepted", true); putLong("requestId", id) }
        }

        override fun serviceControl(action: Int): Bundle {
            sameUid()
            require(action in CoreFixtureContract.CAPTURE_SERVICE..CoreFixtureContract.STALE_SERVICE_INTENTS ||
                action == CoreFixtureContract.REVOKE_SERVICE_OFF_MAIN)
            if (action == CoreFixtureContract.REVOKE_SERVICE_OFF_MAIN) return revokeOffMain()
            return onMain {
                val service = PseudoVpnService.instance
                when (action) {
                    CoreFixtureContract.CAPTURE_SERVICE -> retiredService = checkNotNull(service)
                    CoreFixtureContract.REPLAY_RETIRED_SERVICE -> {
                        val retired = checkNotNull(retiredService)
                        check(retired !== service) { "The original Service has not retired" }
                        retired.onRevoke()
                        retired.onDestroy()
                    }
                    CoreFixtureContract.REVOKE_SERVICE -> checkNotNull(service).onRevoke()
                    CoreFixtureContract.CLOSE_RESOURCES -> checkNotNull(service).closeResources()
                    CoreFixtureContract.SHOW_FOREGROUND -> checkNotNull(service).onStartCommand(
                        Intent(this@CoreFixtureService, PseudoVpnService::class.java).setAction(PseudoVpnService.ACTION_RESOURCE_HOST), 0, 1)
                    CoreFixtureContract.STALE_SERVICE_INTENTS -> {
                        val owned = checkNotNull(service)
                        val waiting = PseudoVpnService::class.java.getDeclaredField("waitingForRuntime").apply { isAccessible = true }
                        check(waiting.getBoolean(owned))
                        owned.onStartCommand(Intent(android.net.VpnService.SERVICE_INTERFACE), 0, 2)
                        owned.onStartCommand(null, 0, 3)
                        owned.onStartCommand(Intent("io.github.monadboxlab.clashpseudo.START"), 0, 4)
                        owned.onStartCommand(Intent("unrecognized"), 0, 5)
                        check(waiting.getBoolean(owned)) { "An old intent revoked the current system restore" }
                    }
                    CoreFixtureContract.FOREGROUND_IO_FAILURE, CoreFixtureContract.FOREGROUND_LINKAGE_FAILURE ->
                        return@onMain foregroundFailure(checkNotNull(service), action)
                }
                Bundle().apply {
                    putBoolean("servicePresent", PseudoVpnService.instance != null)
                    putBoolean("sameService", service === PseudoVpnService.instance)
                    putBoolean("nativeLoaded", NativeCore.isLoaded)
                    putInt("pid", Process.myPid())
                }
            }
        }

        override fun formalRoutes(action: Int, device: Long, inode: Long): Bundle {
            sameUid()
            require(action in 1..4)
            return synchronized(this@CoreFixtureService) {
                val home = AppFiles.core(this@CoreFixtureService)
                check(home.isDirectory && home.canonicalFile == home.absoluteFile)
                val file = File(home, "p5-routes-formal-r7v4.txt")
                if (action == 1) {
                    require(device == 0L && inode == 0L)
                    val created = Os.open(file.path, OsConstants.O_CREAT or OsConstants.O_EXCL or OsConstants.O_WRONLY or OsConstants.O_NOFOLLOW, 0x180)
                    Os.close(created)
                }
                val before = Os.lstat(file.path)
                check(OsConstants.S_ISREG(before.st_mode) && before.st_nlink == 1L)
                if (action != 1) check(before.st_dev == device && before.st_ino == inode) { "Route fixture ownership has changed" }
                if (action == 4) {
                    check(!NativeCore.isLoaded) { "Wait for the previous process to die before deleting the route fixture" }
                    Os.remove(file.path)
                } else {
                    val descriptor = Os.open(file.path, OsConstants.O_WRONLY or OsConstants.O_NOFOLLOW or OsConstants.O_NONBLOCK, 0)
                    try {
                        val actual = Os.fstat(descriptor)
                        check(actual.st_dev == before.st_dev && actual.st_ino == before.st_ino && actual.st_nlink == 1L)
                        Os.ftruncate(descriptor, 0)
                        val bytes = "192.168.100.2/${if (action == 2) 31 else 32}\n".toByteArray(Charsets.UTF_8)
                        check(Os.write(descriptor, bytes, 0, bytes.size) == bytes.size)
                        Os.fsync(descriptor)
                    } finally { Os.close(descriptor) }
                }
                Bundle().apply { putLong("device", before.st_dev); putLong("inode", before.st_ino); putBoolean("removed", action == 4) }
            }
        }

        override fun requestExit(admittedAt: Long, deadline: Long) {
            sameUid()
            require(admittedAt >= 0 && deadline >= admittedAt && deadline - admittedAt <= Contract.OPERATION_ORDINARY_TIMEOUT_MS)
            val remaining = (deadline - SystemClock.elapsedRealtime()).coerceAtLeast(0)
            main.postDelayed({ CoreProcessExit.exit(
                this@CoreFixtureService, checkNotNull(identity!!.getString(Contract.CORE_FIELD_PROCESS_ID)), normal = false) }, remaining)
            worker.execute {
                check(!active.get()) { "Fixture native call has not returned" }
                CoreProcessExit.exit(this@CoreFixtureService,
                    checkNotNull(identity!!.getString(Contract.CORE_FIELD_PROCESS_ID)), normal = true)
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        AppProcess.requireCore(this)
        CoreProcessResources.acquire(this)
        bound = bindService(Intent(this, CoreService::class.java), connection, Context.BIND_AUTO_CREATE)
        check(bound)
    }
    override fun onBind(intent: Intent?): IBinder = binder
    override fun onDestroy() {
        if (bound) unbindService(connection)
        super.onDestroy()
    }

    private fun drainDocument(descriptor: ParcelFileDescriptor) {
        io.execute {
            try {
                ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { input ->
                    val reader = CoreFrames.Reader(input)
                    while (true) {
                        val frame = reader.read()
                        if (frame.kind == Contract.CORE_IPC_FRAME_TERMINAL) {
                            check(JSONObject(CoreFrames.utf8(frame.payload)).getBoolean("complete"))
                            break
                        }
                        check(frame.kind == Contract.CORE_IPC_FRAME_DATA)
                    }
                }
            } catch (error: Throwable) {
                android.util.Log.e("CoreFixture", "Production callback document read failed", error)
            }
        }
    }

    private fun sameUid() = check(Binder.getCallingUid() == Process.myUid()) { "Fixture only accepts the same UID" }
    private fun <T> onMain(action: () -> T): T {
        val task = FutureTask(action)
        main.post(task)
        return task.get(10, TimeUnit.SECONDS)
    }
    private fun revokeOffMain(): Bundle {
        check(Looper.myLooper() != Looper.getMainLooper())
        val service = onMain { checkNotNull(PseudoVpnService.instance) }
        val field = PseudoVpnService::class.java.getDeclaredField("descriptor").apply { isAccessible = true }
        val descriptor = field.get(service) as? ParcelFileDescriptor
        val status = checkNotNull(remote).status(Bundle(checkNotNull(identity)))
        @Suppress("DEPRECATION")
        (status.getParcelable("details") as? ParcelFileDescriptor)?.let(::drainDocument)
        val starting = descriptor == null
        if (starting) {
            check(status.getString(Contract.CORE_FIELD_PHASE) == Contract.CORE_PHASE_LOADING) {
                "A revoke fixture without a TUN must be in the LOADING state of an actual PREPARE"
            }
        } else {
            check(checkNotNull(descriptor).fileDescriptor.valid()) { "onRevoke must close the original FD of the running TUN" }
        }
        // The STARTING recovery event passes through the core main thread only after the test receives the callback receipt.
        val acknowledgement = if (starting) revokeReceiptGate() else null
        try {
            service.onRevoke()
            return Bundle().apply {
                putInt("pid", Process.myPid())
                putString("processId", identity!!.getString(Contract.CORE_FIELD_PROCESS_ID))
                putBoolean("callbackOffMain", true)
                putBoolean("callbackReturned", true)
                putBoolean("starting", starting)
                putBoolean("descriptorAbsent", descriptor == null)
                putBoolean("originalDescriptorClosed", descriptor != null && !descriptor.fileDescriptor.valid())
                putBoolean("descriptorWithdrawn", field.get(service) == null)
                putBoolean("servicePresent", PseudoVpnService.instance != null)
                putBoolean("sameServiceOrDestroyed", PseudoVpnService.instance == null || PseudoVpnService.instance === service)
                if (acknowledgement != null) putParcelable("revokeAcknowledgement", acknowledgement)
            }
        } catch (error: Throwable) {
            try { acknowledgement?.close() } catch (close: Throwable) { if (close !== error) error.addSuppressed(close) }
            throw error
        }
    }

    private fun revokeReceiptGate(): ParcelFileDescriptor {
        val pipe = ParcelFileDescriptor.createPipe()
        val received = FutureTask<Unit> {
            try {
                ParcelFileDescriptor.AutoCloseInputStream(pipe[0]).use { input ->
                    check(input.read() == 1) { "Test did not acknowledge the STARTING revoke receipt" }
                }
            } finally { pipe[1].close() }
        }
        val entered = CountDownLatch(1)
        io.execute(received)
        check(main.post {
            entered.countDown()
            received.get(10, TimeUnit.SECONDS)
        })
        check(entered.await(10, TimeUnit.SECONDS)) { "STARTING revoke receipt gate did not enter the core main thread" }
        return pipe[1]
    }

    private fun foregroundFailure(service: PseudoVpnService, action: Int): Bundle {
        val field = ContextWrapper::class.java.getDeclaredField("mBase").apply { isAccessible = true }
        val before = field.get(service) as Context
        val text = "https://user:pass@fixture.test/?token=原文🙂\nAuthorization: Bearer fixture"
        val failure: Throwable = if (action == CoreFixtureContract.FOREGROUND_IO_FAILURE) IOException(text) else UnsatisfiedLinkError(text)
        val rejected = object : ContextWrapper(before) {
            override fun getSystemService(name: String): Any? {
                if (name == Context.NOTIFICATION_SERVICE) throw failure
                return super.getSystemService(name)
            }
        }
        var actual: Throwable? = null
        field.set(service, rejected)
        try { service.onStartCommand(Intent(service, PseudoVpnService::class.java).setAction(PseudoVpnService.ACTION_RESOURCE_HOST), 0, 1) }
        catch (error: Throwable) { actual = error }
        finally { field.set(service, before) }
        return Bundle().apply {
            putBoolean("sameThrowable", actual === failure)
            putString("expected", failure.stackTraceToString())
            putString("actual", actual?.let { CoreErrors.json(it).toString() })
            putString("actualStack", actual?.stackTraceToString())
            putBoolean("waitingForRuntime", PseudoVpnService::class.java.getDeclaredField("waitingForRuntime")
                .apply { isAccessible = true }.getBoolean(service))
            putBoolean("nativeLoaded", NativeCore.isLoaded)
        }
    }
}

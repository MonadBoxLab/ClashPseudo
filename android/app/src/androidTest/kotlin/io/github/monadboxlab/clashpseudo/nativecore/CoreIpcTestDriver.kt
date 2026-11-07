package io.github.monadboxlab.clashpseudo.nativecore

import android.app.ActivityManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.os.Process
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.debug.CoreFixtureContract
import io.github.monadboxlab.clashpseudo.debug.CoreFixtureService
import io.github.monadboxlab.clashpseudo.debug.ICoreFixture
import io.github.monadboxlab.clashpseudo.nativecore.ipc.ICoreCallback
import io.github.monadboxlab.clashpseudo.nativecore.ipc.ICoreService
import org.json.JSONObject
import org.junit.Assert.*
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.File
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit

/** Actual Binder/FD test client; the default process does not load the native library. */
class CoreIpcTestDriver private constructor(private val fixture: Boolean) : Closeable {
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val context: Context = instrumentation.targetContext
    private val connected = CountDownLatch(1)
    private val died = CountDownLatch(1)
    private val io = Executors.newCachedThreadPool { Thread(it, "test-core-pipe") }
    private val tasks = java.util.concurrent.CopyOnWriteArrayList<Future<*>>()
    private val descriptors = mutableListOf<ParcelFileDescriptor>()
    val statuses = java.util.concurrent.LinkedBlockingQueue<Bundle>()
    val receipts = ConcurrentHashMap<Long, CompletableFuture<JSONObject>>()
    lateinit var binder: IBinder
        private set
    lateinit var identity: Bundle
        private set
    lateinit var service: ICoreService
        private set
    lateinit var debug: ICoreFixture
        private set
    private var bound = false
    private var exitRequested = false
    val processId: String get() = checkNotNull(identity.getString("processId"))
    val pid: Int get() = identity.getInt("pid")
    val deathConfirmed: Boolean get() = died.count == 0L
    private val death = IBinder.DeathRecipient { died.countDown() }
    private val callback = object : ICoreCallback.Stub() {
        override fun onStatus(value: Bundle) {
            tasks.add(io.submit<Unit> { statuses.add(readStatusDetails(value)) })
        }
        override fun onExited(processId: String, requestId: Long, receipt: ParcelFileDescriptor) {
            val completion = receipts.computeIfAbsent(requestId) { CompletableFuture() }
            tasks.add(io.submit<Unit> {
                try {
                    assertEquals(this@CoreIpcTestDriver.processId, processId)
                    completion.complete(readDocument(receipt))
                } catch (error: Throwable) {
                    completion.completeExceptionally(error)
                    throw error
                }
            })
        }
    }
    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, value: IBinder) {
            if (deathConfirmed) { releaseBinding(); return }
            binder = value
            value.linkToDeath(death, 0)
            if (fixture) debug = ICoreFixture.Stub.asInterface(value) else service = ICoreService.Stub.asInterface(value)
            connected.countDown()
        }
        override fun onServiceDisconnected(name: ComponentName) { releaseBinding() }
        override fun onBindingDied(name: ComponentName) { releaseBinding() }
    }

    private fun releaseBinding() {
        if (!bound) return
        context.unbindService(connection)
        bound = false
    }

    init {
        assertNoGoInApplication()
        bound = onMain { context.bindService(Intent(context, if (fixture) CoreFixtureService::class.java else CoreService::class.java),
            connection, Context.BIND_AUTO_CREATE) }
        check(bound) { "Android did not accept the test Service binding" }
        check(connected.await(10, TimeUnit.SECONDS)) { "Actual Service binding did not finish" }
        identity = readStatusDetails(if (fixture) debug.handshake(Contract.CORE_IPC_VERSION) else service.handshake(Contract.CORE_IPC_VERSION, callback))
        assertEquals(Contract.CORE_IPC_VERSION, identity.getInt("protocol"))
        assertTrue(processId.isNotEmpty())
        assertNotEquals("Core must run in a separate process", Process.myPid(), pid)
        assertTrue(binder.isBinderAlive)
        assertNoGoInApplication()
    }

    data class Reply(val value: JSONObject, val terminal: JSONObject,
                     val records: List<JSONObject> = emptyList(), val metadata: List<JSONObject> = emptyList())
    class Pending internal constructor(val id: Long, private val result: Future<Reply>) {
        fun await(seconds: Long = 30): Reply = result.get(seconds, TimeUnit.SECONDS).also { reply ->
            reply.value.optJSONObject("coverage")?.let(::assertCoverage)
        }
        val done get() = result.isDone
    }

    fun fixture(scene: Int, arguments: JSONObject = JSONObject(), config: ByteArray? = null): Pending {
        check(fixture)
        val request = JSONObject(arguments.toString())
        if (scene !in setOf(CoreFixtureContract.COVERAGE, CoreFixtureContract.FD_REUSE)) {
            InstrumentationRegistry.getArguments().getString("nativeCoverageName")?.let { request.put("coverageName", it) }
        }
        return pipes { input, output, writer ->
            val receipt = debug.execute(scene, input, output)
            assertTrue(receipt.getBoolean("accepted"))
            val id = receipt.getLong("requestId")
            assertTrue(id > 0)
            writer(mapOf(Contract.CORE_PART_REQUEST to request.toString().toByteArray(Charsets.UTF_8)) +
                (config?.let { mapOf(Contract.CORE_PART_CONFIG to it) } ?: emptyMap()))
            id
        }
    }

    fun submit(operation: Int, arguments: JSONObject = JSONObject(), inputId: String? = identity.getString("inputId"),
               generation: Long = identity.getLong("generation"), parts: Map<String, ByteArray> = emptyMap(),
               metadata: (JSONObject) -> Unit = {}): Pending {
        check(!fixture)
        val request = JSONObject().put("protocol", Contract.CORE_IPC_VERSION).put("operation", operation)
            .put("processId", processId).put("requestId", 0L).put("inputId", inputId.orEmpty())
            .put("generation", generation).put("networkRevision", identity.getLong("networkRevision"))
            .put("arguments", arguments)
        CoreParts.validate(parts + (Contract.CORE_PART_REQUEST to request.toString().toByteArray(Charsets.UTF_8)))
        return pipes { input, output, writer ->
            val control = Bundle(identity).apply {
                putInt("operation", operation); putLong("generation", generation); putString("inputId", inputId)
                remove("cleanupCandidates"); remove("error")
            }
            val receipt = service.submit(control, input, output)
            assertTrue(receipt.getBoolean("accepted"))
            val id = receipt.getLong("requestId")
            assertTrue(id > 0)
            request.put("requestId", id)
            metadata(request)
            // Receive the remotely allocated requestId before writing metadata and starting the writer.
            writer(parts + (Contract.CORE_PART_REQUEST to request.toString().toByteArray(Charsets.UTF_8)))
            id
        }
    }

    private fun pipes(admit: (ParcelFileDescriptor, ParcelFileDescriptor, (Map<String, ByteArray>) -> Unit) -> Long): Pending {
        val input = ParcelFileDescriptor.createPipe()
        val output = ParcelFileDescriptor.createPipe()
        synchronized(descriptors) { descriptors.addAll(input); descriptors.addAll(output) }
        val result = io.submit<Reply> {
            ParcelFileDescriptor.AutoCloseInputStream(output[0]).use { source ->
                val reader = CoreFrames.Reader(source)
                val data = ByteArrayOutputStream()
                val records = mutableListOf<JSONObject>()
                val metadata = mutableListOf<JSONObject>()
                var total = 0L
                while (true) {
                    val frame = reader.read()
                    total += frame.payload.size
                    check(total <= Contract.CORE_IPC_QUEUE_BYTES) { "Result for this fixed scenario exceeds 16 MiB" }
                    if (frame.kind == Contract.CORE_IPC_FRAME_DATA) {
                        data.write(frame.payload)
                    } else if (frame.kind == Contract.CORE_IPC_FRAME_RECORD) {
                        records.add(JSONObject(CoreFrames.utf8(frame.payload)))
                    } else if (frame.kind == Contract.CORE_IPC_FRAME_METADATA) {
                        metadata.add(JSONObject(CoreFrames.utf8(frame.payload)))
                    } else if (frame.kind == Contract.CORE_IPC_FRAME_TERMINAL) {
                        val bytes = data.toByteArray()
                        return@submit Reply(if (bytes.isEmpty()) JSONObject() else JSONObject(CoreFrames.utf8(bytes)),
                            JSONObject(CoreFrames.utf8(frame.payload)), records.toList(), metadata.toList())
                    } else error("Unknown frame kind: ${frame.kind}")
                }
                @Suppress("UNREACHABLE_CODE") error("Result is missing a terminal frame")
            }
        }
        tasks.add(result)
        val id = try {
            input[0].use { source -> output[1].use { target -> admit(source, target) { parts ->
                CoreParts.validate(parts)
                tasks.add(io.submit<Unit> { ParcelFileDescriptor.AutoCloseOutputStream(input[1]).use { CoreParts.write(it, parts) } })
            } } }
        } catch (error: Throwable) {
            input.forEach { it.close() }; output.forEach { it.close() }; throw error
        }
        return Pending(id, result)
    }

    fun prepare(body: ByteArray, vpn: Boolean = false, inputId: String = java.util.UUID.randomUUID().toString(),
                configId: String = "fixture", revision: Int = 1, mode: String = "rule", access: String = "all",
                packages: List<String> = emptyList(), overrides: String = "[]",
                options: JSONObject = JSONObject()): Reply {
        val purpose = if (vpn) Contract.CORE_PURPOSE_RUNNING else Contract.CORE_PURPOSE_PREVIEW
        val deadline = SystemClock.elapsedRealtime() + Contract.OPERATION_ORDINARY_TIMEOUT_MS
        val args = JSONObject().put("purpose", purpose).put("vpnIntent", vpn).put("lanIntent", false)
            .put("configId", configId).put("revision", revision).put("mode", mode)
            .put("access", access).put("packages", org.json.JSONArray(packages)).put("deadline", deadline)
        val nativeOptions = JSONObject(options.toString()).put("purpose", purpose).put("generation", 1)
            .put("composition", "test-$inputId").put("vpnIntent", vpn).put("lanIntent", false)
        val pending = submit(Contract.CORE_OPERATION_PREPARE, args, inputId, generation = 1,
            parts = mapOf(Contract.CORE_PART_CONFIG to body, Contract.CORE_PART_OVERRIDES to overrides.toByteArray(Charsets.UTF_8),
                Contract.CORE_PART_OPTIONS to nativeOptions.toString().toByteArray(Charsets.UTF_8)))
        val reply = pending.await(120)
        assertTrue("Platform call must actually exit", receipt(pending.id).getBoolean("exited"))
        identity = status()
        return reply
    }

    fun status(): Bundle = readStatusDetails(service.status(controlIdentity()))
    fun controlIdentity(): Bundle = Bundle().apply { putInt("protocol", Contract.CORE_IPC_VERSION); putString("processId", processId) }
    fun receipt(id: Long): JSONObject = receipts.computeIfAbsent(id) { CompletableFuture() }.get(10, TimeUnit.SECONDS)
    fun cancel(id: Long): Reply {
        val current = status()
        identity = current
        val cancellation = submit(Contract.CORE_OPERATION_CANCEL, JSONObject().put("targetRequestId", id),
            current.getString("inputId"), current.getLong("generation"))
        return cancellation.await().also { assertTrue(receipt(cancellation.id).getBoolean("exited")) }
    }

    fun exit(admittedAt: Long = SystemClock.elapsedRealtime(),
             deadline: Long = admittedAt + Contract.OPERATION_ORDINARY_TIMEOUT_MS) {
        if (deathConfirmed) return
        exitRequested = true
        try {
            if (fixture) debug.requestExit(admittedAt, deadline)
            else service.requestExit(controlIdentity().apply {
                putLong("admittedAt", admittedAt); putLong("deadline", deadline); putString("reason", "stop")
            })
        } catch (error: android.os.DeadObjectException) {
            android.util.Log.i("CoreIpcTestDriver", "Binder died before the exit request returned: processId=$processId", error)
        }
        assertTrue("The matching Binder DeathRecipient callback must be received", died.await(
            (deadline - SystemClock.elapsedRealtime()).coerceAtLeast(0) + 10_000, TimeUnit.MILLISECONDS))
        assertFalse(binder.isBinderAlive)
        onMain { releaseBinding() }
        assertNoGoInApplication()
    }

    fun awaitDeath(seconds: Long = 30) {
        assertTrue("Wait for actual core process death", died.await(seconds, TimeUnit.SECONDS))
        assertFalse(binder.isBinderAlive)
        onMain { releaseBinding() }
    }

    override fun close() {
        var failure: Throwable? = null
        try { if (!deathConfirmed) exit() } catch (error: Throwable) { failure = error }
        try {
            synchronized(descriptors) { descriptors.forEach { it.close() } }
            for (task in tasks) {
                try { task.get(10, TimeUnit.SECONDS) }
                catch (error: java.util.concurrent.ExecutionException) {
                    // Process death may end unfinished pipes with actual EOF; callers must still check their results.
                    if (!deathConfirmed) throw error.cause ?: error
                }
            }
            io.shutdown()
            check(io.awaitTermination(10, TimeUnit.SECONDS)) { "Local FD I/O has not exited" }
        } catch (error: Throwable) { if (failure == null) failure = error else if (failure !== error) failure.addSuppressed(error) }
        finally { onMain { releaseBinding() } }
        failure?.let { throw it }
    }

    companion object {
        fun readDocument(descriptor: ParcelFileDescriptor): JSONObject =
            ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { input ->
                val reader = CoreFrames.Reader(input)
                val bytes = ByteArrayOutputStream()
                while (true) {
                    val frame = reader.read()
                    when (frame.kind) {
                        Contract.CORE_IPC_FRAME_DATA -> bytes.write(frame.payload)
                        Contract.CORE_IPC_FRAME_TERMINAL -> {
                            assertTrue(JSONObject(CoreFrames.utf8(frame.payload)).getBoolean("complete"))
                            return@use JSONObject(CoreFrames.utf8(bytes.toByteArray()))
                        }
                        else -> error("Document contains an unknown frame kind: ${frame.kind}")
                    }
                }
                @Suppress("UNREACHABLE_CODE") error("Document is missing a terminal frame")
            }

        @Suppress("DEPRECATION")
        fun readStatusDetails(source: Bundle): Bundle = Bundle(source).apply {
            (getParcelable<ParcelFileDescriptor>("details"))?.let { descriptor ->
                remove("details")
                val detail = readDocument(descriptor)
                detail.keys().forEach { key ->
                    val value = detail.get(key)
                    when (value) {
                        JSONObject.NULL -> remove(key)
                        is Boolean -> putBoolean(key, value)
                        is Int -> putInt(key, value)
                        is Long -> putLong(key, value)
                        is String -> putString(key, value)
                        else -> putString(key, value.toString())
                    }
                }
            }
        }

        fun bindVpnResource(context: Context): Closeable {
            val connected = CountDownLatch(1)
            val connection = object : ServiceConnection {
                override fun onServiceConnected(name: ComponentName, binder: IBinder) { connected.countDown() }
                override fun onServiceDisconnected(name: ComponentName) = Unit
            }
            val bound = onMain { context.bindService(Intent(context, io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService::class.java)
                .setAction(android.net.VpnService.SERVICE_INTERFACE), connection, Context.BIND_AUTO_CREATE) }
            check(bound)
            check(connected.await(10, TimeUnit.SECONDS))
            return Closeable { onMain { context.unbindService(connection) } }
        }
        fun injectCommunicationFailure(context: Context, error: Throwable) {
            val client = CoreClient.get(context)
            val state = CoreClient::class.java.getDeclaredField("state").apply { isAccessible = true }.get(client) as android.os.Handler
            val done = CompletableFuture<Unit>()
            state.post {
                try {
                    val owner = CoreClient::class.java.getDeclaredField("binding").apply { isAccessible = true }.get(client)
                    checkNotNull(owner)
                    val method = CoreClient::class.java.declaredMethods.single { it.name == "communicationLost" }
                        .apply { isAccessible = true }
                    method.invoke(client, owner, error)
                    done.complete(Unit)
                } catch (failure: Throwable) { done.completeExceptionally(failure) }
            }
            done.get(10, TimeUnit.SECONDS)
        }
        fun assertCoverage(value: JSONObject) {
            assertTrue(value.toString(), value.getBoolean("newFile"))
            assertEquals(value.toString(), 0, value.getInt("write"))
            assertTrue(value.toString(), value.getBoolean("regular"))
            assertTrue(value.toString(), value.getLong("bytes") > 0)
            val file = File(value.getString("path"))
            assertTrue(file.isFile)
            assertEquals(value.getLong("bytes"), file.length())
        }
        fun production() = CoreIpcTestDriver(false)
        fun fixture() = CoreIpcTestDriver(true)
        fun assertNoGoInApplication() {
            assertFalse("The default process must not load libmihomo_bridge", File("/proc/self/maps").useLines { lines ->
                lines.any { it.contains("libmihomo_bridge.so") }
            })
        }
        fun <T> onMain(action: () -> T): T {
            val task = FutureTask(action)
            InstrumentationRegistry.getInstrumentation().runOnMainSync(task)
            return task.get(10, TimeUnit.SECONDS)
        }
        fun servicePresent(context: Context, type: Class<*>): Boolean {
            @Suppress("DEPRECATION")
            return context.getSystemService(ActivityManager::class.java).getRunningServices(100)
                .any { it.service == ComponentName(context, type) }
        }
        fun removeFixtureHome(context: Context, value: JSONObject) {
            val home = File(value.getString("home"))
            assertEquals(context.cacheDir.canonicalFile, home.parentFile!!.canonicalFile)
            assertTrue(home.name.startsWith("core-fixture-"))
            assertEquals(File(context.cacheDir.canonicalFile, home.name), home.canonicalFile)
            assertTrue("Cannot delete this run's fixture directory", home.deleteRecursively())
        }
    }
}

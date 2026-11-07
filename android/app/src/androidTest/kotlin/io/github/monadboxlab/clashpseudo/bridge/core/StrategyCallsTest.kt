package io.github.monadboxlab.clashpseudo.bridge.core

import android.os.Build
import android.os.DeadObjectException
import android.os.Bundle
import android.os.Handler
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.nativecore.CoreClient
import io.github.monadboxlab.clashpseudo.nativecore.CoreIpcTestDriver
import io.github.monadboxlab.clashpseudo.nativecore.CorePlatformTestDriver
import io.github.monadboxlab.clashpseudo.nativecore.CoreResourceGate
import io.github.monadboxlab.clashpseudo.nativecore.input.CoreInput
import io.github.monadboxlab.clashpseudo.nativecore.ipc.ICoreService
import java.io.Closeable
import java.io.IOException
import java.util.concurrent.CompletableFuture
import java.util.concurrent.Executor
import java.util.concurrent.ExecutorService
import java.util.concurrent.FutureTask
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import io.github.monadboxlab.clashpseudo.bridge.core.CoreBridgeIpcScenario.Companion.collection
import io.github.monadboxlab.clashpseudo.bridge.core.CoreBridgeIpcScenario.Companion.failure
import io.github.monadboxlab.clashpseudo.bridge.core.CoreBridgeIpcScenario.Companion.success
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class StrategyCallsTest {
    @Test fun queuedPreparationCancellationKeepsTheActualInputUntilDrainAndReportsUnstartedWork() {
        for (linkage in listOf(false, true)) {
            val platform = CorePlatformTestDriver()
            val visibility = platform.keepPreviewVisible()
            try {
                platform.handshake()
                ExitControl(platform, Contract.CORE_OPERATION_PREPARE).use { control ->
                    control.holdPreparationInput.set(true)
                    val work = CompletableFuture.supplyAsync {
                        platform.prepare(strategyInput(), vpn = false, owner = "queued-prepare-owner")
                    }
                    platform.await("Actual PREPARE is admitted while the original input FD remains held") {
                        control.heldPreparations.isNotEmpty() && control.client.requestBusy
                    }
                    val source = platform.status()
                    val id = checkNotNull(control.heldPreparations.peek()).first
                    val cancellation = platform.channel(Contract.CORE_CHANNEL_CANCEL,
                        mapOf("processId" to source["processId"], "requestId" to id)) as Map<*, *>
                    assertEquals(false, cancellation[Contract.CORE_FIELD_STARTED])
                    assertEquals(true, cancellation["cancelled"])
                    assertEquals(id, (cancellation["targetRequestId"] as Number).toLong())
                    val original = cleanupFailure(linkage)
                    control.rejection.set(original)
                    val replies = AtomicInteger()
                    val cleanup = CompletableFuture<Throwable?>()
                    val at = SystemClock.elapsedRealtime()
                    control.client.exit(source["processId"] as String, at,
                        at + Contract.OPERATION_ORDINARY_TIMEOUT_MS, "reconnect") {
                        replies.incrementAndGet()
                        cleanup.complete(it)
                    }
                    assertSame(original, cleanup.get(10, TimeUnit.SECONDS))
                    assertEquals(1, replies.get())
                    assertFalse(work.isDone)
                    assertTrue(control.client.requestBusy)
                    assertEquals(0, control.acceptedExitTasks.get())
                    assertNull(CoreResourceGate.forApplication(platform.context).tryAcquire())
                    control.releasePreparations()
                    val actual = work.get(30, TimeUnit.SECONDS)
                    assertEquals(Contract.CORE_ERROR_CANCELLED, failure(actual).getString("code"))
                    assertTrue(actual.terminal.getJSONObject("nativeReceipt").getBoolean("exited"))
                    platform.await("Original PREPARE input, output, and receipt actually finish") { !control.client.requestBusy }
                    assertEquals(1, replies.get())
                    control.rejection.set(null)
                    platform.exit()
                    control.assertExited(source)
                }
            } finally { try { platform.exit() } finally { visibility.close() } }
        }
    }

    @Test fun cancelledReadyPreparationRejectsNewWorkUntilReceiptDrainAndCannotInvalidateReplacement() {
        for (linkage in listOf<Boolean?>(null, false, true)) {
            val platform = CorePlatformTestDriver()
            val visibility = platform.keepPreviewVisible()
            val client = CoreClient.get(platform.context)
            val admittedAt = SystemClock.elapsedRealtime()
            val deadline = admittedAt + Contract.OPERATION_ORDINARY_TIMEOUT_MS
            lateinit var old: Map<String, Any?>
            try {
                platform.handshake()
                ExitControl(platform, Contract.CORE_OPERATION_PREPARE).use { control ->
                    control.holdReceipt.set(true)
                    val work = CompletableFuture.supplyAsync {
                        platform.prepare(strategyInput(), vpn = false, owner = "prepare-owner", admittedAt = admittedAt)
                    }
                    platform.await("PREPARE is READY while the original receipt FD remains unread") {
                        if (work.isDone) {
                            work.get(0, TimeUnit.SECONDS)
                            fail("PREPARE must not finish before the receipt FD is released")
                        }
                        control.heldReceipts.isNotEmpty() && client.status()["phase"] == Contract.CORE_PHASE_READY
                    }
                    old = platform.status()
                    val generation = (old["generation"] as Number).toLong()
                    control.assertReceiptPending()
                    assertTrue(client.view.current(generation))
                    client.cancelOwner("other-owner")
                    control.onState { }
                    CoreIpcTestDriver.onMain { }
                    assertEquals(0, control.cancellations.get())
                    assertTrue(client.view.current(generation))
                    assertEquals("running", client.lifecycle.snapshot().stage)

                    val original = linkage?.let(::cleanupFailure)
                    control.cancelRejection.set(original)
                    client.cancelOwner("prepare-owner")
                    platform.await("The correct owner's actual CANCEL is submitted") { control.cancellations.get() == 1 }
                    val requestId = control.heldRequestId()
                    val cancellation = runCatching {
                        platform.channel(Contract.CORE_CHANNEL_CANCEL,
                            mapOf("processId" to old["processId"], "requestId" to requestId))
                    }
                    if (original == null) {
                        val response = cancellation.getOrThrow() as Map<*, *>
                        assertEquals(true, response["cancelled"])
                        assertEquals(requestId, (response["targetRequestId"] as Number).toLong())
                    } else {
                        val error = cancellation.exceptionOrNull()
                        assertTrue(error is CorePlatformTestDriver.ChannelFailure)
                        val detail = JSONObject((error as CorePlatformTestDriver.ChannelFailure).details as String)
                        assertEquals(original.javaClass.name, detail.getString("type"))
                        assertEquals(original.stackTraceToString(), detail.getString("stack"))
                        assertEquals(original.cause!!.stackTraceToString(), detail.getJSONObject("cause").getString("stack"))
                        assertEquals(original.suppressed.single().stackTraceToString(),
                            detail.getJSONArray("suppressed").getJSONObject(0).getString("stack"))
                    }
                    assertEquals(2, control.cancellations.get())
                    assertEquals(Contract.CORE_PHASE_STOPPING, client.status()["phase"])
                    assertEquals(Contract.CORE_PHASE_STOPPING, client.lifecycle.snapshot().stage)
                    assertEquals("reconnect", client.lifecycle.snapshot().exitReason)
                    assertFalse(client.view.current(generation))
                    assertFalse(work.isDone)
                    assertTrue(client.requestBusy)
                    control.assertReceiptPending()
                    control.assertReadyIdentity(old)
                    assertNull(CoreResourceGate.forApplication(platform.context).tryAcquire())
                    assertEquals(0, control.submissions.get())
                    assertEquals(0, control.acceptedExitTasks.get())

                    // The actual Service still returns READY; a status refresh for the same process must not restore application authority.
                    assertEquals(Contract.CORE_PHASE_STOPPING, platform.handshake()["phase"])
                    val businessBefore = control.businessSubmissions.get()
                    val rejected = runCatching { platform.query(Contract.CORE_OPERATION_STRATEGIES) }.exceptionOrNull()
                    assertTrue(rejected is CorePlatformTestDriver.ChannelFailure)
                    assertEquals(Contract.CORE_ERROR_IDENTITY_MISMATCH,
                        (rejected as CorePlatformTestDriver.ChannelFailure).code)
                    assertEquals(businessBefore, control.businessSubmissions.get())
                    control.releaseReceipts()
                    val actual = work.get(30, TimeUnit.SECONDS)
                    assertTrue(success(actual).getBoolean("prepared"))
                    assertEquals(old["processId"], actual.value.getString("processId"))
                    assertEquals(old["inputId"], actual.value.getString("inputId"))
                    assertTrue(actual.terminal.getJSONObject("nativeReceipt").getBoolean("exited"))
                    platform.await("All FDs of the original PREPARE and CANCEL have finished") { !client.requestBusy }
                    assertEquals(Contract.CORE_PHASE_STOPPING, platform.handshake()["phase"])
                    assertFalse(client.view.current(generation))
                    assertNull(CoreResourceGate.forApplication(platform.context).tryAcquire())
                    val released = CompletableFuture<Throwable?>()
                    client.exit(old["processId"] as String, admittedAt, deadline, "reconnect") { released.complete(it) }
                    assertNull(released.get(30, TimeUnit.SECONDS))
                    assertEquals(1, control.submissions.get())
                    assertEquals(1, control.acceptedExitTasks.get())
                    val exit = checkNotNull(control.exitRequests.poll())
                    assertEquals(admittedAt, exit.getLong(Contract.CORE_FIELD_ADMITTED_AT))
                    assertEquals(deadline, exit.getLong(Contract.CORE_FIELD_DEADLINE))
                    control.assertExited(old)
                }

                val late = CompletableFuture<Throwable?>()
                val oldCleanup = Runnable {
                    client.exit(old["processId"] as String, admittedAt, deadline, "reconnect") { late.complete(it) }
                }
                success(platform.prepare(strategyInput("replacement", 2), vpn = false))
                ExitControl(platform).use { replacement ->
                    val current = platform.status()
                    assertNotEquals(old["processId"], current["processId"])
                    assertNotEquals(old["inputId"], current["inputId"])
                    assertNotEquals(old["composition"], current["composition"])
                    assertEquals(old["generation"], current["generation"])
                    oldCleanup.run()
                    assertEquals("Exit request belongs to an old core process", checkNotNull(late.get(10, TimeUnit.SECONDS)).message)
                    client.cancelOwner("prepare-owner")
                    replacement.onState { }
                    assertEquals(0, replacement.cancellations.get())
                    assertEquals(0, replacement.submissions.get())
                    replacement.assertReadyIdentity(current)
                    assertEquals(Contract.CORE_PHASE_READY, platform.handshake()["phase"])
                    assertEquals(current["coreLifecycle"], platform.status()["coreLifecycle"])
                    assertTrue(client.view.current((current["generation"] as Number).toLong()))
                    assertNull(CoreResourceGate.forApplication(platform.context).tryAcquire())
                    platform.exit()
                    replacement.assertExited(current)
                }
            } finally { try { platform.exit() } finally { visibility.close() } }
        }
    }

    @Test fun rejectedPreparationCleanupKeepsTheActualContextAndReceiptUntilExplicitRelease() {
        for (linkage in listOf(false, true)) for (workFails in listOf(false, true)) {
            val platform = CorePlatformTestDriver()
            val visibility = platform.keepPreviewVisible()
            try {
                success(platform.prepare(strategyInput(), vpn = false))
                ExitControl(platform).use { control ->
                    val source = platform.status()
                    val original = cleanupFailure(linkage)
                    control.rejection.set(original)
                    control.holdReceipt.set(true)
                    val work = CompletableFuture.supplyAsync {
                        platform.query(Contract.CORE_OPERATION_STRATEGY_SELECT,
                            mapOf("name" to "出口🌐", "choice" to mapOf("type" to "select",
                                "member" to if (workFails) "missing-$ORIGINAL" else "REJECT")))
                    }
                    platform.await("Actual native receipt is waiting to be read") {
                        if (work.isDone) {
                            work.get(0, TimeUnit.SECONDS)
                            fail("The original call must not finish before receipt reading is released")
                        }
                        control.heldReceipts.isNotEmpty()
                    }
                    control.assertReceiptPending()
                    assertFalse(work.isDone)
                    assertTrue(control.client.requestBusy)
                    val release = CompletableFuture<Throwable?>()
                    val replies = AtomicInteger()
                    val admitted = SystemClock.elapsedRealtime()
                    control.client.exit(source["processId"] as String, admitted, admitted + 30_000, "cancelled") {
                        replies.incrementAndGet()
                        release.complete(it)
                    }
                    assertSame(original, release.get(10, TimeUnit.SECONDS))
                    assertEquals(1, replies.get())
                    assertEquals(1, control.submissions.get())
                    assertEquals(0, control.acceptedExitTasks.get())
                    control.assertRejectedContext(source, original)
                    control.assertReceiptPending()
                    assertFalse(work.isDone)
                    assertTrue(control.client.requestBusy)
                    control.releaseReceipts()
                    val captured = work.get(30, TimeUnit.SECONDS)
                    if (workFails) assertEquals("member-missing", failure(captured).getString("message"))
                    else assertTrue(success(captured).getBoolean("applied"))
                    assertTrue(captured.terminal.getJSONObject("nativeReceipt").getBoolean("exited"))
                    platform.await("The original call and receipt FD actually finish") { !control.client.requestBusy }
                    assertEquals(1, replies.get())
                    control.assertRejectedContext(source, original)
                    control.rejection.set(null)
                    platform.exit()
                    assertEquals(1, control.acceptedExitTasks.get())
                    control.assertExited(source)
                }
            } finally { try { platform.exit() } finally { visibility.close() } }
        }
    }

    @Test fun delayedCancelledCleanupCannotReleaseTheReplacementProcessOrItsLease() {
        val platform = CorePlatformTestDriver()
        val visibility = platform.keepPreviewVisible()
        val queued = LinkedBlockingQueue<Runnable>()
        val lateReply = CompletableFuture<Throwable?>()
        val replies = AtomicInteger()
        try {
            success(platform.prepare(strategyInput(), vpn = false))
            val client = CoreClient.get(platform.context)
            val old = platform.status()
            val oldProcess = old["processId"] as String
            val oldGeneration = (old["generation"] as Number).toLong()
            val admitted = SystemClock.elapsedRealtime()
            queued.add(Runnable {
                client.exit(oldProcess, admitted, admitted + 30_000, "cancelled") {
                    replies.incrementAndGet()
                    lateReply.complete(it)
                }
            })
            assertEquals(1, queued.size)
            assertTrue(client.view.current(oldGeneration))
            platform.exit()
            assertFalse(client.view.current(oldGeneration))
            assertEquals(Contract.CORE_PHASE_EXITED, platform.status()["phase"])
            success(platform.prepare(strategyInput("replacement", 2), vpn = false))
            ExitControl(platform).use { replacement ->
                val source = platform.status()
                assertNotEquals(oldProcess, source["processId"])
                assertNotEquals(old["inputId"], source["inputId"])
                assertNotEquals(old["composition"], source["composition"])
                assertTrue(client.view.current((source["generation"] as Number).toLong()))
                checkNotNull(queued.poll(2, TimeUnit.SECONDS)).run()
                val error = checkNotNull(lateReply.get(10, TimeUnit.SECONDS))
                assertEquals("Exit request belongs to an old core process", error.message)
                assertEquals(1, replies.get())
                assertTrue(queued.isEmpty())
                assertEquals(0, replacement.submissions.get())
                assertEquals(0, replacement.acceptedExitTasks.get())
                replacement.assertReadyIdentity(source)
                assertEquals(source["coreLifecycle"], platform.status()["coreLifecycle"])
                assertTrue(client.view.current((source["generation"] as Number).toLong()))
                assertNull(CoreResourceGate.forApplication(platform.context).tryAcquire())
                val disconnected = DeadObjectException(ORIGINAL).apply {
                    initCause(IOException("original exit cause: $ORIGINAL"))
                    addSuppressed(IOException("original exit close failure: $ORIGINAL"))
                }
                replacement.rejection.set(disconnected)
                val actualExit = CompletableFuture<Throwable?>()
                val exitReplies = AtomicInteger()
                val exitAdmitted = SystemClock.elapsedRealtime()
                client.exit(source["processId"] as String, exitAdmitted, exitAdmitted + 30_000, "stop") {
                    exitReplies.incrementAndGet()
                    actualExit.complete(it)
                }
                replacement.onState { }
                CoreIpcTestDriver.onMain { }
                replacement.onState { }
                assertFalse("Binder failure must not fake actual process death", actualExit.isDone)
                assertEquals(0, exitReplies.get())
                assertEquals(1, replacement.submissions.get())
                assertEquals(0, replacement.acceptedExitTasks.get())
                replacement.assertRejectedContext(source, disconnected)
                replacement.rejection.set(null)
                platform.exit()
                assertNull(actualExit.get(10, TimeUnit.SECONDS))
                assertEquals(1, exitReplies.get())
                assertEquals(2, replacement.submissions.get())
                assertEquals(1, replacement.acceptedExitTasks.get())
                replacement.assertExited(source)
                replacement.onState { }
                CoreIpcTestDriver.onMain { }
                assertEquals(1, exitReplies.get())
                assertEquals(1, replies.get())
            }
        } finally { try { platform.exit() } finally { visibility.close() } }
    }

    @Test fun idleCleanupExecutorRejectionKeepsTheActualLeaseWithoutReschedulingItself() {
        for (linkage in listOf(false, true)) {
            val platform = CorePlatformTestDriver()
            val visibility = platform.keepPreviewVisible()
            try {
                success(platform.prepare(strategyInput(), vpn = false))
                ExitControl(platform).use { control ->
                    val source = platform.status()
                    val original = cleanupFailure(linkage)
                    control.rejection.set(original)
                    control.expireIdle()
                    platform.await("Original idle cleanup error") {
                        control.client.status()["phase"] == Contract.CORE_PHASE_COMMUNICATION_LOST
                    }
                    control.onState { }
                    CoreIpcTestDriver.onMain { }
                    control.onState { }
                    assertEquals(1, control.submissions.get())
                    assertEquals(0, control.acceptedExitTasks.get())
                    control.assertRejectedContext(source, original)
                    control.assertIdleNotScheduled()
                    control.runIdleCallback()
                    control.onState { }
                    CoreIpcTestDriver.onMain { }
                    assertEquals(1, control.submissions.get())
                    control.assertIdleNotScheduled()
                    control.rejection.set(null)
                    platform.exit()
                    assertEquals(2, control.submissions.get())
                    assertEquals(1, control.acceptedExitTasks.get())
                    control.assertExited(source)
                }
            } finally { try { platform.exit() } finally { visibility.close() } }
        }
    }

    private fun strategyInput(id: String = "fixture", revision: Int = 1) =
        CoreInput(id, revision, null, CoreBridgeIpcScenario.STRATEGIES.toByteArray(Charsets.UTF_8), "{}".toByteArray(), name = id)

    private fun cleanupFailure(linkage: Boolean): Throwable =
        (if (linkage) UnsatisfiedLinkError(ORIGINAL) else RejectedExecutionException(ORIGINAL)).apply {
            initCause(IOException("original cleanup cause: $ORIGINAL"))
            addSuppressed(IOException("original cleanup close failure: $ORIGINAL"))
        }

    /** Control only scheduling of the original Binder exit call and receipt read; other calls keep using the original Service, FDs, and executors. */
    private class ExitControl(private val platform: CorePlatformTestDriver,
                              private val receiptOperation: Int = Contract.CORE_OPERATION_STRATEGY_SELECT) : Closeable {
        val client = CoreClient.get(platform.context)
        private val state = field("state").get(client) as Handler
        private val connection = checkNotNull(onState { field("connection").get(client) })
        private val remoteField = connection.javaClass.getDeclaredField("remote").apply { isAccessible = true }
        private val remote = remoteField.get(connection) as ICoreService
        private val ioField = field("io")
        private val io = ioField.get(client) as ExecutorService
        private val visible = field("visible")
        private val busy = field("operationBusy")
        private val hiddenAt = field("hiddenAt")
        private val idle = field("previewIdle").get(client) as Runnable
        private val previousVisible = onState { visible.getBoolean(client) }
        private val previousBusy = onState { busy.getBoolean(client) }
        private val previousHiddenAt = onState { hiddenAt.getLong(client) }
        private val processId = client.status()["processId"] as String
        @Suppress("UNCHECKED_CAST")
        private val documents = field("documentReads").get(client) as Map<ParcelFileDescriptor, String>
        val rejection = AtomicReference<Throwable?>()
        val cancelRejection = AtomicReference<Throwable?>()
        val cancellations = AtomicInteger()
        val businessSubmissions = AtomicInteger()
        val exitRequests = LinkedBlockingQueue<Bundle>()
        val submissions = AtomicInteger()
        val acceptedExitTasks = AtomicInteger()
        val holdReceipt = AtomicBoolean()
        val holdPreparationInput = AtomicBoolean()
        val heldPreparations = LinkedBlockingQueue<Pair<Long, Runnable>>()
        val heldReceipts = LinkedBlockingQueue<Runnable>()
        private var heldRequest: Pair<String, Long>? = null
        private val cleanup = Executor { task ->
            submissions.incrementAndGet()
            rejection.get()?.let { throw it }
            task.run()
        }
        private val controlledRemote = object : ICoreService by remote {
            override fun submit(request: Bundle, input: ParcelFileDescriptor, output: ParcelFileDescriptor): Bundle {
                if (request.getInt(Contract.CORE_FIELD_OPERATION) == Contract.CORE_OPERATION_CANCEL) {
                    cancellations.incrementAndGet()
                    cancelRejection.get()?.let { throw it }
                } else businessSubmissions.incrementAndGet()
                if (request.getInt(Contract.CORE_FIELD_OPERATION) == Contract.CORE_OPERATION_PREPARE && holdPreparationInput.get()) {
                    val source = ParcelFileDescriptor.dup(input.fileDescriptor)
                    val pipe = ParcelFileDescriptor.createPipe()
                    try {
                        val accepted = pipe[0].use { remote.submit(request, it, output) }
                        heldPreparations.add(accepted.getLong(Contract.CORE_FIELD_REQUEST_ID) to Runnable {
                            ParcelFileDescriptor.AutoCloseInputStream(source).use { original ->
                                ParcelFileDescriptor.AutoCloseOutputStream(pipe[1]).use { target -> original.copyTo(target) }
                            }
                        })
                        return accepted
                    } catch (error: Throwable) {
                        source.close()
                        pipe.forEach { runCatching { it.close() } }
                        throw error
                    }
                }
                return remote.submit(request, input, output)
            }
            override fun requestExit(request: Bundle) {
                exitRequests.add(Bundle(request))
                cleanup.execute {
                    acceptedExitTasks.incrementAndGet()
                    remote.requestExit(request)
                }
            }
        }
        private val controlledIo = object : ExecutorService by io {
            override fun execute(task: Runnable) {
                if (holdReceipt.get() && Thread.currentThread() === state.looper.thread && receiptReadPending())
                    heldReceipts.add(task)
                else io.execute(task)
            }
        }

        init {
            platform.await("Prepare call and status FD actually finish", timeoutMs = 10_000) {
                onState {
                    if (client.requestBusy) false else {
                        visible.setBoolean(client, true)
                        busy.setBoolean(client, false)
                        state.removeCallbacks(idle)
                        remoteField.set(connection, controlledRemote)
                        ioField.set(client, controlledIo)
                        true
                    }
                }
            }
            assertTrue(remote.asBinder().isBinderAlive)
            CoreIpcTestDriver.assertNoGoInApplication()
        }

        private fun receiptReadPending(): Boolean {
            if (heldRequest != null) return false
            @Suppress("UNCHECKED_CAST")
            val calls = field("calls").get(client) as Map<Pair<String, Long>, Any>
            val entry = calls.entries.singleOrNull { (key, call) ->
                key.first == processId && call.javaClass.getDeclaredField("operation").apply { isAccessible = true }
                    .getInt(call) == receiptOperation
            } ?: return false
            val call = entry.value
            val receipt = call.javaClass.getDeclaredField("receiptDescriptor").apply { isAccessible = true }
                .get(call) as? ParcelFileDescriptor ?: return false
            if (documents[receipt] != processId) return false
            // onExited submits a read immediately after setting the descriptor in the original state task; defer only that submission.
            heldRequest = entry.key
            return true
        }

        private fun field(name: String) = CoreClient::class.java.getDeclaredField(name).apply { isAccessible = true }

        fun <T> onState(action: () -> T): T {
            val task = FutureTask(action)
            check(state.post(task))
            return task.get(10, TimeUnit.SECONDS)
        }

        fun releasePreparations() = onState {
            holdPreparationInput.set(false)
            while (true) io.execute(heldPreparations.poll()?.second ?: break)
        }

        fun releaseReceipts() = onState {
            holdReceipt.set(false)
            while (true) io.execute(heldReceipts.poll() ?: break)
        }

        fun heldRequestId(): Long = onState { checkNotNull(heldRequest).second }

        fun assertReceiptPending() = onState {
            @Suppress("UNCHECKED_CAST")
            val calls = field("calls").get(client) as Map<Pair<String, Long>, Any>
            val key = checkNotNull(heldRequest)
            assertEquals(processId, key.first)
            val call = checkNotNull(calls[key])
            assertEquals(receiptOperation,
                call.javaClass.getDeclaredField("operation").apply { isAccessible = true }.getInt(call))
            val receipt = call.javaClass.getDeclaredField("receiptDescriptor").apply { isAccessible = true }
                .get(call) as ParcelFileDescriptor
            fun flag(name: String) = call.javaClass.getDeclaredField(name).apply { isAccessible = true }.getBoolean(call)
            assertTrue(flag("nativeExited"))
            assertTrue(flag("writeExited"))
            assertFalse(flag("receiptExited"))
            assertFalse(flag("ioExited"))
            assertEquals(processId, documents[receipt])
            assertEquals(1, heldReceipts.size)
        }

        fun assertReadyIdentity(source: Map<String, Any?>) {
            val identity = Bundle().apply {
                putInt("protocol", Contract.CORE_IPC_VERSION)
                putString("processId", processId)
            }
            val actual = CoreIpcTestDriver.readStatusDetails(remote.status(identity))
            assertEquals(Contract.CORE_PHASE_READY, actual.getString("phase"))
            for (name in listOf("processId", "inputId", "configId", "purpose"))
                assertEquals(name, source[name], actual.getString(name))
            for (name in listOf("generation", "networkRevision"))
                assertEquals(name, (source[name] as Number).toLong(), actual.getLong(name))
            assertEquals((source["revision"] as Number).toInt(), actual.getInt("revision"))
            val projected = client.status()
            assertTrue((source["composition"] as String).isNotBlank())
            for (name in listOf("processId", "inputId", "generation", "composition"))
                assertEquals(name, source[name], projected[name])
            assertTrue(remote.asBinder().isBinderAlive)
        }

        fun assertRejectedContext(source: Map<String, Any?>, original: Throwable) {
            assertReadyIdentity(source)
            val projected = client.status()
            assertEquals(Contract.CORE_PHASE_COMMUNICATION_LOST, projected["phase"])
            val error = JSONObject(projected["error"] as String)
            assertEquals(Contract.CORE_ERROR_COMMUNICATION_LOST, error.getString("code"))
            assertEquals(original.javaClass.name, error.getString("type"))
            assertEquals(original.message, error.getString("message"))
            assertEquals(original.stackTraceToString(), error.getString("stack"))
            assertEquals(original.cause!!.stackTraceToString(), error.getJSONObject("cause").getString("stack"))
            assertEquals(original.suppressed.single().stackTraceToString(),
                error.getJSONArray("suppressed").getJSONObject(0).getString("stack"))
            assertFalse(client.view.current((source["generation"] as Number).toLong()))
            assertNull(CoreResourceGate.forApplication(platform.context).tryAcquire())
        }

        fun expireIdle() = onState {
            visible.setBoolean(client, false)
            busy.setBoolean(client, false)
            hiddenAt.setLong(client, SystemClock.elapsedRealtime() - 30_001)
            CoreClient::class.java.getDeclaredMethod("schedulePreviewIdle").apply { isAccessible = true }.invoke(client)
        }

        fun runIdleCallback() = onState { idle.run() }

        fun assertIdleNotScheduled() = onState {
            if (Build.VERSION.SDK_INT >= 29) assertFalse(state.hasCallbacks(idle))
            else {
                val messages = StringBuilder()
                state.dump({ messages.append(it).append('\n') }, "")
                assertFalse(messages.toString(), messages.contains("callback=${idle.javaClass.name}"))
            }
        }

        fun assertExited(source: Map<String, Any?>) {
            assertEquals(source["processId"], client.status()["processId"])
            assertEquals(Contract.CORE_PHASE_EXITED, client.status()["phase"])
            assertFalse(remote.asBinder().isBinderAlive)
            assertFalse(client.view.current((source["generation"] as Number).toLong()))
            assertFalse(client.requestBusy)
            val lease = CoreResourceGate.forApplication(platform.context).tryAcquire()
            assertNotNull(lease)
            checkNotNull(lease).close()
            CoreIpcTestDriver.assertNoGoInApplication()
        }

        override fun close() {
            releasePreparations()
            releaseReceipts()
            onState {
                state.removeCallbacks(idle)
                remoteField.set(connection, remote)
                ioField.set(client, io)
                visible.setBoolean(client, previousVisible)
                busy.setBoolean(client, previousBusy)
                hiddenAt.setLong(client, previousHiddenAt)
            }
        }
    }

    private companion object {
        const val ORIGINAL = "https://user:pass@fixture.test/?token=原文🙂\nAuthorization: Bearer fixture"
    }

    @Suppress("DEPRECATION")
    @Test fun idlePreviewKeepsItsRealLeaseWhileVisibleOrBusyAndReleasesItAfterActualProcessDeath() {
        val platform = io.github.monadboxlab.clashpseudo.nativecore.CorePlatformTestDriver()
        val manager = platform.context.getSystemService(android.app.ActivityManager::class.java)
        val coreService = android.content.ComponentName(platform.context,
            io.github.monadboxlab.clashpseudo.nativecore.CoreService::class.java)
        val runtimeService = android.content.ComponentName(platform.context,
            io.github.monadboxlab.clashpseudo.logic.AppRuntimeService::class.java)
        fun started(service: android.content.ComponentName): Boolean? = manager.getRunningServices(Int.MAX_VALUE)
            .firstOrNull { it.service == service }?.started
        val client = io.github.monadboxlab.clashpseudo.nativecore.CoreClient.get(platform.context)
        val state = client.javaClass.getDeclaredField("state").apply { isAccessible = true }.get(client) as android.os.Handler
        val visible = client.javaClass.getDeclaredField("visible").apply { isAccessible = true }
        val busy = client.javaClass.getDeclaredField("operationBusy").apply { isAccessible = true }
        val hiddenAt = client.javaClass.getDeclaredField("hiddenAt").apply { isAccessible = true }
        val idle = client.javaClass.getDeclaredField("previewIdle").apply { isAccessible = true }.get(client) as Runnable
        val schedule = client.javaClass.getDeclaredMethod("schedulePreviewIdle").apply { isAccessible = true }
        fun onState(action: () -> Unit) {
            val done = java.util.concurrent.CompletableFuture<Unit>()
            assertTrue(state.post { try { action(); done.complete(Unit) } catch (error: Throwable) { done.completeExceptionally(error) } })
            done.get(10, java.util.concurrent.TimeUnit.SECONDS)
        }
        var wasVisible = false
        var wasBusy = false
        var wasHiddenAt = 0L
        onState {
            wasVisible = visible.getBoolean(client)
            wasBusy = busy.getBoolean(client)
            wasHiddenAt = hiddenAt.getLong(client)
            visible.setBoolean(client, true)
            busy.setBoolean(client, false)
        }
        try {
            success(platform.prepare(io.github.monadboxlab.clashpseudo.nativecore.input.CoreInput(
                "fixture", 1, null, CoreBridgeIpcScenario.STRATEGIES.toByteArray(Charsets.UTF_8), "{}".toByteArray(), name = "fixture"), vpn = false))
            platform.await("CoreService is started while AppRuntimeService retains its bound lifecycle") {
                started(coreService) == true && started(runtimeService) == false
            }
            val captured = platform.status()["processId"]
            assertTrue(platform.context.stopService(android.content.Intent().setComponent(coreService)))
            platform.await("CoreService ends its started lifecycle while still bound") { started(coreService) == false }
            client.view.setVisible(false)
            platform.await("Restore the started lifecycle in the original core process when entering the background") { started(coreService) == true }
            assertEquals(captured, platform.status()["processId"])
            val duplicateAt = android.os.SystemClock.elapsedRealtime() - 1
            onState { hiddenAt.setLong(client, duplicateAt) }
            client.view.setVisible(false)
            onState { assertEquals("Duplicate hidden notifications preserve the original idle start time", duplicateAt, hiddenAt.getLong(client)) }
            client.view.setVisible(true)
            onState { idle.run() }
            assertEquals(captured, platform.status()["processId"])
            assertEquals(Contract.CORE_PHASE_READY, platform.status()["phase"])
            assertNull(io.github.monadboxlab.clashpseudo.nativecore.CoreResourceGate.forApplication(platform.context).tryAcquire())
            onState {
                visible.setBoolean(client, false)
                busy.setBoolean(client, true)
                hiddenAt.setLong(client, android.os.SystemClock.elapsedRealtime() - 30_001)
                idle.run()
            }
            assertEquals(Contract.CORE_PHASE_READY, platform.status()["phase"])
            assertNull(io.github.monadboxlab.clashpseudo.nativecore.CoreResourceGate.forApplication(platform.context).tryAcquire())
            io.github.monadboxlab.clashpseudo.nativecore.CoreIpcTestDriver.onMain { }
            onState {
                visible.setBoolean(client, true)
                busy.setBoolean(client, false)
                hiddenAt.setLong(client, android.os.SystemClock.elapsedRealtime() - 30_001)
            }
            val readAt = android.os.SystemClock.elapsedRealtime()
            success(platform.query(Contract.CORE_OPERATION_SNAPSHOT))
            platform.await("A non-LOGS call actually finishes and updates the idle start time") {
                var finished = false
                onState { finished = !client.requestBusy && hiddenAt.getLong(client) >= readAt }
                finished
            }
            io.github.monadboxlab.clashpseudo.nativecore.CoreIpcTestDriver.onMain { }
            onState {
                assertTrue("Restart the timer after a non-LOGS call actually finishes", hiddenAt.getLong(client) >= readAt)
                visible.setBoolean(client, false)
                busy.setBoolean(client, true)
                hiddenAt.setLong(client, android.os.SystemClock.elapsedRealtime() - 30_001)
            }
            val idleAt = android.os.SystemClock.elapsedRealtime()
            client.view.setOperationBusy(false)
            onState {
                assertTrue("Restart the timer after the application operation finishes", hiddenAt.getLong(client) >= idleAt)
                assertEquals(Contract.CORE_PHASE_READY, client.status()["phase"])
                assertNull(io.github.monadboxlab.clashpseudo.nativecore.CoreResourceGate.forApplication(platform.context).tryAcquire())
                hiddenAt.setLong(client, android.os.SystemClock.elapsedRealtime() - 30_001)
                schedule.invoke(client)
            }
            platform.await("Actual process exit for idle PREVIEW") { client.status()["phase"] == Contract.CORE_PHASE_EXITED }
            assertEquals("previewExpired", client.lifecycle.snapshot().exitReason)
            platform.await("CoreService and AppRuntimeService finish after core exit") {
                started(coreService) == null && started(runtimeService) == null
            }
            assertEquals(captured, platform.status()["processId"])
            assertEquals(false, platform.status()["vpnRunning"])
            val released = io.github.monadboxlab.clashpseudo.nativecore.CoreResourceGate.forApplication(platform.context).tryAcquire()
            assertNotNull(released)
            released!!.close()
            io.github.monadboxlab.clashpseudo.nativecore.CoreIpcTestDriver.assertNoGoInApplication()
        } finally {
            onState {
                state.removeCallbacks(idle)
                visible.setBoolean(client, wasVisible)
                busy.setBoolean(client, wasBusy)
                hiddenAt.setLong(client, wasHiddenAt)
            }
            platform.exit()
        }
    }
    @Test fun utf8ChoicesReadBackFromTheSameRealCoreContext() {
        CoreBridgeIpcScenario(CoreBridgeIpcScenario.STRATEGIES).use { core ->
            val source = collection(core.query(Contract.CORE_OPERATION_STRATEGIES))
            assertTrue(source.any { it.getString("name") == "出口🌐" })
            for (member in listOf("节点🌐", "REJECT", "节点🌐")) {
                val selected = success(core.query(Contract.CORE_OPERATION_STRATEGY_SELECT,
                    JSONObject().put("name", "出口🌐").put("choice", JSONObject().put("type", "select").put("member", member))))
                assertTrue(selected.getBoolean("applied"))
                val group = collection(core.query(Contract.CORE_OPERATION_STRATEGIES)).single { it.getString("name") == "出口🌐" }
                assertEquals(member, group.getString("now"))
                core.assertSameContext()
            }
        }
    }

    @Test fun nativeRejectionKeepsItsActualReasonAndLeavesTheActualChoiceUnchanged() {
        CoreBridgeIpcScenario(CoreBridgeIpcScenario.STRATEGIES).use { core ->
            val before = collection(core.query(Contract.CORE_OPERATION_STRATEGIES)).single { it.getString("name") == "出口🌐" }.getString("now")
            val member = "https://user:pass@fixture.test/?token=原文🙂"
            val rejected = failure(core.query(Contract.CORE_OPERATION_STRATEGY_SELECT,
                JSONObject().put("name", "出口🌐").put("choice", JSONObject().put("type", "select").put("member", member))))
            assertEquals("member-missing", rejected.getString("message"))
            assertEquals(before, collection(core.query(Contract.CORE_OPERATION_STRATEGIES)).single { it.getString("name") == "出口🌐" }.getString("now"))
            core.assertSameContext()
        }
    }

    @Test fun wrongFdIdentityCannotApplyAQueuedChoiceAndTheNextRequestCanRetry() {
        CoreBridgeIpcScenario(CoreBridgeIpcScenario.STRATEGIES).use { core ->
            val args = JSONObject().put("name", "出口🌐").put("choice", JSONObject().put("type", "select").put("member", "节点🌐"))
            val before = collection(core.query(Contract.CORE_OPERATION_STRATEGIES)).single { it.getString("name") == "出口🌐" }.getString("now")
            val rejected = core.await(core.start(Contract.CORE_OPERATION_STRATEGY_SELECT, args) { it.put("inputId", "replacement") })
            assertEquals(Contract.CORE_ERROR_IDENTITY_MISMATCH, failure(rejected).getString("code"))
            assertEquals(before, collection(core.query(Contract.CORE_OPERATION_STRATEGIES)).single { it.getString("name") == "出口🌐" }.getString("now"))
            assertTrue(success(core.query(Contract.CORE_OPERATION_STRATEGY_SELECT, args)).getBoolean("applied"))
            assertEquals("节点🌐", collection(core.query(Contract.CORE_OPERATION_STRATEGIES)).single { it.getString("name") == "出口🌐" }.getString("now"))
        }
    }

    @Test fun capturedReadKeepsItsNativeSourceAfterItsProcessHasExited() {
        val original = CoreBridgeIpcScenario(CoreBridgeIpcScenario.STRATEGIES).use { core ->
            core.query(Contract.CORE_OPERATION_STRATEGIES).also { collection(it) } to core.driver.processId
        }
        CoreBridgeIpcScenario(CoreBridgeIpcScenario.STRATEGIES).use { replacement ->
            assertNotEquals(original.second, replacement.driver.processId)
            val old = original.first
            assertTrue(collection(old).any { it.getString("name") == "出口🌐" })
            assertEquals(old.metadata.single().getString("source"), old.terminal.getString("source"))
            replacement.assertSameContext()
        }
    }
}

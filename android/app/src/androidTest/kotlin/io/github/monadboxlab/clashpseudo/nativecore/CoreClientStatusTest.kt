package io.github.monadboxlab.clashpseudo.nativecore

import android.content.ComponentName
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.DeadObjectException
import android.os.Handler
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.os.RemoteException
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.nativecore.input.CoreInput
import io.github.monadboxlab.clashpseudo.nativecore.ipc.ICoreCallback
import io.github.monadboxlab.clashpseudo.nativecore.ipc.ICoreService
import io.github.monadboxlab.clashpseudo.storage.AppFiles
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.Closeable
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit

/** Exercise the production status consumer with real immutable records and independently drained FD documents. */
class CoreClientStatusTest {
    @org.junit.Before fun awaitStartup() {
        val driver = CorePlatformTestDriver()
        val work = androidx.work.WorkManager.getInstance(driver.context)
        driver.await("Startup task finishes") {
            work.getWorkInfosForUniqueWork("update-reconcile").get(5, TimeUnit.SECONDS)
                .let { it.isNotEmpty() && it.all { item -> item.state.isFinished } } &&
                io.github.monadboxlab.clashpseudo.bridge.AppBridge.operationId == null &&
                !io.github.monadboxlab.clashpseudo.bridge.AppBridge.logic.busy
        }
    }

    private class Fixture(private val vpn: Boolean = false) : Closeable {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val client = CoreClient.get(context)
        private fun field(name: String) = CoreClient::class.java.getDeclaredField(name).apply { isAccessible = true }
        private val state = field("state").get(client) as Handler
        private val connectionClass = CoreClient::class.java.declaredClasses.single { it.simpleName == "Connection" }
        private val bindingClass = CoreClient::class.java.declaredClasses.single { it.simpleName == "Binding" }
        private val previousStatus = field("statusValue").get(client)
        private val previousEvent = client.onEvent
        private val previousChanged = client.changed
        private val records = mutableListOf<java.io.File>()
        private val descriptors = mutableListOf<ParcelFileDescriptor>()
        val events = java.util.concurrent.LinkedBlockingQueue<Map<String, Any?>>()
        val exitRequests = java.util.concurrent.LinkedBlockingQueue<Bundle>()
        val processId = "status-${UUID.randomUUID()}"
        val inputId = UUID.randomUUID().toString()
        var exitFailure: Throwable? = null
        var unbindFailure: Throwable? = null
        var binderAlive = true
        var bindCount = 0
        var unbindCount = 0
        private val registeredBindings = mutableSetOf<ServiceConnection>()
        private val previousContext = field("context").get(client) as Context
        private val bindingContext = object : ContextWrapper(previousContext) {
            override fun bindService(intent: Intent, connection: ServiceConnection, flags: Int): Boolean {
                assertEquals(Context.BIND_AUTO_CREATE, flags)
                assertTrue(registeredBindings.add(connection))
                bindCount++
                return true
            }
            override fun unbindService(connection: ServiceConnection) {
                assertTrue("Only a registered binding can be released", registeredBindings.remove(connection))
                unbindCount++
                unbindFailure?.let { throw it }
            }
        }
        private val remote = object : ICoreService.Stub() {
            override fun handshake(protocol: Int, callback: ICoreCallback): Bundle = error("Unexpected handshake")
            override fun status(identity: Bundle): Bundle = ready()
            override fun submit(request: Bundle, input: ParcelFileDescriptor, output: ParcelFileDescriptor): Bundle = error("Unexpected submit")
            override fun requestExit(request: Bundle) {
                exitRequests.add(request)
                exitFailure?.let { throw it }
            }
        }
        private var deathRecipient: IBinder.DeathRecipient? = null
        private val binder = object : IBinder by remote.asBinder() {
            override fun isBinderAlive(): Boolean = binderAlive
            override fun linkToDeath(recipient: IBinder.DeathRecipient, flags: Int) {
                check(deathRecipient == null)
                deathRecipient = recipient
            }
            override fun unlinkToDeath(recipient: IBinder.DeathRecipient, flags: Int): Boolean {
                assertSame(deathRecipient, recipient)
                deathRecipient = null
                return true
            }
        }
        private val binding = bindingClass.declaredConstructors.single().apply { isAccessible = true }.newInstance(client) as ServiceConnection
        private val death = IBinder.DeathRecipient { state.post { onDeath() } }
        private val owner = connectionClass.declaredConstructors.single().apply { isAccessible = true }.newInstance(
            binding, remote, binder, death)
        private val accept = CoreClient::class.java.getDeclaredMethod("acceptStatus", connectionClass, Bundle::class.java,
            kotlin.Function1::class.java).apply { isAccessible = true }

        init {
            onState {
                assertNull("The status fixture requires no connected core", field("connection").get(client))
                assertNull("The status fixture requires no pending binding", field("binding").get(client))
                assertTrue(bindingContext.bindService(Intent(context, CoreService::class.java), binding, Context.BIND_AUTO_CREATE))
                bindingClass.getDeclaredField("bound").apply { isAccessible = true }.setBoolean(binding, true)
                field("context").set(client, bindingContext)
                field("binding").set(client, binding)
                binder.linkToDeath(death, 0)
                connectionClass.getDeclaredField("deathLinked").apply { isAccessible = true }.setBoolean(owner, true)
                connectionClass.getDeclaredField("processId").apply { isAccessible = true }.set(owner, processId)
                field("connection").set(client, owner)
                client.onEvent = { events.add(it) }
                client.changed = {}
            }
        }

        fun ready(input: String = inputId, revision: Long = 1) = Bundle().apply {
            putInt("protocol", Contract.CORE_IPC_VERSION)
            putString("processId", processId); putString("inputId", input)
            putLong("generation", 1); putLong("networkRevision", 7)
            putString("configId", "status-fixture"); putInt("revision", 1)
            putString("purpose", Contract.CORE_PURPOSE_RUNNING); putString("phase", Contract.CORE_PHASE_READY)
            putBoolean("vpnIntent", vpn); putBoolean("lanIntent", true)
            putBoolean("vpnRunning", vpn); putBoolean("lanRunning", true)
            putLong(Contract.CORE_FIELD_LISTENER_REVISION, revision)
        }

        fun record(large: Boolean = false): String {
            val overrides = JSONArray()
            val composition = JSONArray().put("status-fixture").put(1)
            repeat(if (large) 2000 else 1) { index ->
                val id = "part-${index}-${"x".repeat(32)}"
                overrides.put(JSONObject().put("id", id).put("revision", 1).put("name", id)
                    .put("role", "lanProxy").put("mode", "replace").put("body", "listeners: []"))
                composition.put(JSONArray().put(id).put(1).put("replace"))
            }
            val input = CoreInput("status-fixture", 1, "rule", "rules: []".toByteArray(), "{}".toByteArray(),
                overrides.toString().toByteArray(), composition.toString(), name = "Status fixture")
            val raw = JSONObject(CoreFrames.utf8(input.snapshotBytes())).put("inputId", inputId)
                .put("vpnIntent", vpn).put("lanIntent", true)
            val file = AppFiles.runRecord(context, inputId)
            CorePrivateFiles.write(file, raw.toString().toByteArray())
            records.add(file)
            return composition.toString()
        }

        fun accept(snapshot: Bundle): CompletableFuture<Throwable?> {
            val completed = CompletableFuture<Throwable?>()
            val callback: (Throwable?) -> Unit = { completed.complete(it) }
            onState { accept.invoke(client, owner, snapshot, callback) }
            return completed
        }

        fun details(snapshot: Bundle, listeners: JSONArray): Pair<CompletableFuture<Throwable?>, () -> Unit> {
            val pipe = ParcelFileDescriptor.createPipe()
            descriptors.addAll(pipe)
            snapshot.putParcelable("details", pipe[0])
            val pending = accept(snapshot)
            return pending to {
                ParcelFileDescriptor.AutoCloseOutputStream(pipe[1]).use {
                    CoreDocuments.write(it, JSONObject().put("lanListeners", listeners).toString().toByteArray())
                }
            }
        }

        fun <T> onState(block: () -> T): T {
            if (android.os.Looper.myLooper() == state.looper) return block()
            val task = FutureTask(block)
            check(state.post(task))
            return task.get(10, TimeUnit.SECONDS)
        }

        fun readSnapshot(value: JSONObject, beforeDelivery: () -> Unit) {
            val input = ParcelFileDescriptor.createPipe()
            val output = ParcelFileDescriptor.createPipe()
            val callClass = CoreClient::class.java.declaredClasses.single { it.simpleName == "Call" }
            val call = callClass.declaredConstructors.single().apply { isAccessible = true }
                .newInstance(processId, 73L, Contract.CORE_OPERATION_SNAPSHOT, inputId, "fixture", 1L, 7L, input[1], output[0], "status-test")
            (callClass.getDeclaredField("exited").apply { isAccessible = true }.get(call) as java.util.concurrent.CountDownLatch).countDown()
            @Suppress("UNCHECKED_CAST")
            val calls = field("calls").get(client) as MutableMap<Pair<String, Long>, Any>
            val result = CompletableFuture<Any?>()
            try {
                onState { assertNull(calls.put(processId to 73L, call)) }
                CoreIpcTestDriver.onMain {
                    client.handle(io.flutter.plugin.common.MethodCall(Contract.CORE_CHANNEL_READ,
                        mapOf("processId" to processId, "requestId" to 73L)), object : io.flutter.plugin.common.MethodChannel.Result {
                        override fun success(value: Any?) { result.complete(value) }
                        override fun error(code: String, message: String?, details: Any?) { result.completeExceptionally(AssertionError(message)) }
                        override fun notImplemented() { result.completeExceptionally(AssertionError("Missing coreRead")) }
                    })
                }
                beforeDelivery()
                ParcelFileDescriptor.AutoCloseOutputStream(output[1]).use {
                    CoreFrames.write(it, CoreFrames.Frame(Contract.CORE_IPC_FRAME_DATA, value.toString().toByteArray()))
                }
                val read = result.get(5, TimeUnit.SECONDS) as Map<*, *>
                assertEquals(value.toString(), CoreFrames.utf8(read["payload"] as ByteArray))
                onState { }
            } finally {
                onState { calls.remove(processId to 73L) }
                (input + output).forEach { it.close() }
            }
        }

        fun refresh(): Throwable? {
            val reply = CompletableFuture<Throwable?>()
            client.refreshPresentation { reply.complete(it) }
            return reply.get(5, TimeUnit.SECONDS)
        }

        fun disconnect() = onState { field("connection").set(client, null) }

        private fun onDeath() {
            CoreClient::class.java.getDeclaredMethod("died", connectionClass).apply { isAccessible = true }.invoke(client, owner)
        }

        fun confirmDeath() {
            onState { binderAlive = false; checkNotNull(deathRecipient).binderDied() }
            onState { }
        }

        val exitReplyCount = java.util.concurrent.atomic.AtomicInteger()
        fun exit(process: String = processId, admittedAt: Long = SystemClock.elapsedRealtime(),
                 deadline: Long = admittedAt + 30_000): CompletableFuture<Throwable?> {
            val result = CompletableFuture<Throwable?>()
            client.exit(process, admittedAt, deadline, "stop") {
                exitReplyCount.incrementAndGet()
                result.complete(it)
            }
            onState { }
            return result
        }

        fun handshakeFailure(): Throwable? {
            val result = CompletableFuture<Pair<Map<String, Any?>?, Throwable?>>()
            client.handshake { value, error -> result.complete(value to error) }
            val reply = result.get(5, TimeUnit.SECONDS)
            assertNull(reply.first)
            return reply.second
        }

        fun assertRetiring() = onState {
            assertSame(owner, field("connection").get(client))
            assertSame(binding, field("binding").get(client))
            assertFalse(bindingClass.getDeclaredField("bound").apply { isAccessible = true }.getBoolean(binding))
            assertFalse(registeredBindings.contains(binding))
            assertSame(death, deathRecipient)
            assertEquals(1, bindCount)
            assertEquals(1, unbindCount)
        }

        fun lateConnection() {
            binding.onServiceConnected(ComponentName(context, CoreService::class.java), remote.asBinder())
            onState { }
        }

        fun assertRetired() = onState {
            assertNull(field("connection").get(client))
            assertNull(field("binding").get(client))
            assertNull(deathRecipient)
            assertEquals(1, unbindCount)
        }

        fun awaitRecovery() {
            CorePlatformTestDriver(context).await("Immutable input read drains") {
                onState { field("inputReads").getInt(client) == 0 }
            }
        }

        override fun close() {
            try {
                descriptors.forEach { it.close() }
                awaitRecovery()
                CorePlatformTestDriver(context).await("Status documents drain") {
                    onState { (field("documentReads").get(client) as Map<*, *>).values.none { it == processId } }
                }
                CoreIpcTestDriver.onMain {}
            } finally {
                onState {
                    registeredBindings.clear()
                    field("connection").set(client, null)
                    field("binding").set(client, null)
                    field("context").set(client, previousContext)
                    (field("exitWaiters").get(client) as MutableMap<*, *>).entries.removeAll { it.value == processId }
                    field("statusValue").set(client, previousStatus)
                    @Suppress("UNCHECKED_CAST")
                    CoreClient.session.project(previousStatus as Map<String, Any?>)
                    client.onEvent = previousEvent
                    client.changed = previousChanged
                }
                records.forEach { assertTrue(it.delete()) }
            }
        }
    }

    @Test fun coldLanAndVpnLanClientsRestoreFullCompositionAndEmitAWakeup() {
        for (vpn in listOf(false, true)) Fixture(vpn).use { f ->
            val composition = f.record(large = true)
            assertTrue(composition.toByteArray().size > Contract.CORE_IPC_CONTROL_BYTES)
            f.accept(f.ready()).get(5, TimeUnit.SECONDS)
            f.awaitRecovery()
            assertEquals(composition, f.client.status()["composition"])
            val event = checkNotNull(f.events.poll(5, TimeUnit.SECONDS))
            assertEquals(Contract.CORE_EVENT_INPUT_RESTORED, event["event"])
            assertEquals(f.inputId, event["inputId"])
            assertEquals(Contract.CORE_PHASE_READY, f.client.status()["phase"])
        }
    }

    @Test fun asynchronousRecordReadCannotRestoreStoppedOrReplacedInput() {
        for (replace in listOf(false, true)) Fixture().use { f ->
            f.record()
            f.onState {
                f.accept(f.ready())
                f.accept(if (replace) f.ready(UUID.randomUUID().toString())
                    else f.ready().apply { putString("phase", Contract.CORE_PHASE_STOPPING) })
            }
            f.awaitRecovery()
            assertNull(f.client.status()["composition"])
            if (!replace) assertEquals(Contract.CORE_PHASE_STOPPING, f.client.status()["phase"])
            assertTrue(f.events.isEmpty())
        }
    }

    @Test fun disconnectedInputReadRemainsBusyUntilItsIoTaskDrains() {
        Fixture().use { f ->
            assertFalse(f.client.requestBusy)
            f.record()
            val executor = java.util.concurrent.Executors.newSingleThreadExecutor()
            val entered = java.util.concurrent.CountDownLatch(1)
            val release = java.util.concurrent.CountDownLatch(1)
            val ioField = CoreClient::class.java.getDeclaredField("io").apply { isAccessible = true }
            val previous = f.client.io
            try {
                executor.execute {
                    entered.countDown()
                    check(release.await(10, TimeUnit.SECONDS)) { "Input read barrier was not released" }
                }
                assertTrue(entered.await(5, TimeUnit.SECONDS))
                f.onState { ioField.set(f.client, executor) }
                f.accept(f.ready()).get(5, TimeUnit.SECONDS)
                assertTrue(f.client.requestBusy)
                f.disconnect()
                assertTrue("Detached input work still owns the application I/O gate", f.client.requestBusy)
                release.countDown()
                f.awaitRecovery()
                assertFalse(f.client.requestBusy)
                assertNull(f.client.status()[Contract.CORE_FIELD_COMPOSITION])
                assertTrue(f.events.isEmpty())
            } finally {
                release.countDown()
                executor.shutdown()
                try {
                    assertTrue("Input read executor drains", executor.awaitTermination(10, TimeUnit.SECONDS))
                    f.awaitRecovery()
                } finally { f.onState { ioField.set(f.client, previous) } }
            }
        }
    }

    @Test fun missingOrMismatchedRecordLeavesConfirmedSmallStatusAvailable() {
        for (mismatch in listOf(false, true)) Fixture().use { f ->
            if (mismatch) {
                f.record()
                val file = AppFiles.runRecord(f.context, f.inputId)
                val raw = JSONObject(CoreFrames.utf8(checkNotNull(CorePrivateFiles.read(file, AppFiles.MAX_RUN_RECORD_BYTES))))
                CorePrivateFiles.write(file, raw.put("inputId", "other-input").toString().toByteArray())
            }
            f.accept(f.ready()).get(5, TimeUnit.SECONDS)
            f.awaitRecovery()
            assertNull(f.client.status()["composition"])
            assertEquals(f.processId, f.client.status()["processId"])
            assertEquals(Contract.CORE_PHASE_READY, f.client.status()["phase"])
            assertTrue(f.events.isEmpty())
        }
    }

    @Test fun missingRunRecordDoesNotBlockStopOrCompleteBeforeProcessDeath() {
        Fixture().use { f ->
            f.accept(f.ready()).get(5, TimeUnit.SECONDS)
            f.awaitRecovery()
            val exited = CompletableFuture<Throwable?>()
            val at = android.os.SystemClock.elapsedRealtime()
            f.client.exit(f.processId, at, at + 30_000, "stop") { exited.complete(it) }
            val request = checkNotNull(f.exitRequests.poll(5, TimeUnit.SECONDS))
            assertEquals(f.processId, request.getString("processId"))
            assertFalse(exited.isDone)
            assertEquals(Contract.CORE_PHASE_STOPPING, f.client.status()["phase"])
            f.accept(f.ready()).get(5, TimeUnit.SECONDS)
            assertEquals(Contract.CORE_PHASE_STOPPING, f.client.status()["phase"])
            f.confirmDeath()
            assertNull(exited.get(5, TimeUnit.SECONDS))
        }
    }

    @Test fun exitReleasesAutoCreateButRetainsOwnerUntilDeathOnReturnAndDeadObjectException() {
        for (remoteDied in listOf(false, true)) Fixture().use { f ->
            f.accept(f.ready()).get(5, TimeUnit.SECONDS)
            f.awaitRecovery()
            if (remoteDied) f.exitFailure = DeadObjectException()
            val exited = f.exit()
            f.assertRetiring()
            assertFalse("Unbinding does not confirm process death", exited.isDone)
            f.lateConnection()
            f.assertRetiring()
            f.onState { f.binderAlive = false }
            assertNotNull("A dead Binder must fail handshake before its death callback", f.handshakeFailure())
            f.assertRetiring()
            assertFalse(exited.isDone)
            f.confirmDeath()
            assertNull(exited.get(5, TimeUnit.SECONDS))
            f.assertRetired()
            CoreIpcTestDriver.onMain { }
            assertEquals(1, f.exitReplyCount.get())
        }
    }

    @Test fun exitPreservesRemoteFailureWhenUnbindAlsoFailsAndDeathArrivesLater() {
        Fixture().use { f ->
            val failure = RemoteException("Exit request failed")
            f.exitFailure = failure
            f.unbindFailure = IllegalArgumentException("Binding was already removed")
            val exited = f.exit()
            assertSame(failure, exited.get(5, TimeUnit.SECONDS))
            f.assertRetiring()
            assertEquals(Contract.CORE_PHASE_COMMUNICATION_LOST, f.client.status()["phase"])
            f.confirmDeath()
            CoreIpcTestDriver.onMain { }
            assertEquals(1, f.exitReplyCount.get())
            f.assertRetired()
        }
    }

    @Test fun exitRejectsInvalidAdmissionAndOldIdentityWithoutDroppingBinding() {
        Fixture().use { f ->
            assertNotNull(f.exit(admittedAt = -1, deadline = 1).get(5, TimeUnit.SECONDS))
            assertNotNull(f.exit(process = "old-process").get(5, TimeUnit.SECONDS))
            f.onState {
                assertEquals(1, f.bindCount)
                assertEquals(0, f.unbindCount)
                assertTrue(f.exitRequests.isEmpty())
            }
        }
    }

    @Test fun exitKeepsOriginalDeadlineAndDoesNotReplyAgainAfterLateDeath() {
        Fixture().use { f ->
            f.exitFailure = DeadObjectException()
            val deadline = SystemClock.elapsedRealtime() - 1
            val admittedAt = deadline - 1000
            val exited = f.exit(admittedAt = admittedAt, deadline = deadline)
            val request = checkNotNull(f.exitRequests.poll(5, TimeUnit.SECONDS))
            assertEquals(admittedAt, request.getLong(Contract.CORE_FIELD_ADMITTED_AT))
            assertEquals(deadline, request.getLong(Contract.CORE_FIELD_DEADLINE))
            assertNotNull(exited.get(Contract.OPERATION_UI_GRACE_MS + 5000L, TimeUnit.MILLISECONDS))
            f.assertRetiring()
            f.confirmDeath()
            CoreIpcTestDriver.onMain { }
            assertEquals(1, f.exitReplyCount.get())
            f.assertRetired()
        }
    }

    @Test fun confirmedDeathStillBlocksExitAndHandshakeUntilLocalDocumentIoDrains() {
        Fixture().use { f ->
            f.accept(f.ready()).get(5, TimeUnit.SECONDS)
            f.awaitRecovery()
            val executor = java.util.concurrent.Executors.newSingleThreadExecutor()
            val entered = java.util.concurrent.CountDownLatch(1)
            val release = java.util.concurrent.CountDownLatch(1)
            val ioField = CoreClient::class.java.getDeclaredField("io").apply { isAccessible = true }
            val previous = f.client.io
            try {
                executor.execute {
                    entered.countDown()
                    check(release.await(10, TimeUnit.SECONDS)) { "Document read barrier was not released" }
                }
                assertTrue(entered.await(5, TimeUnit.SECONDS))
                f.onState { ioField.set(f.client, executor) }
                val document = f.details(f.ready(revision = 2), JSONArray())
                val exited = f.exit()
                f.confirmDeath()
                f.assertRetired()
                assertFalse("A closed descriptor does not finish its queued reader", document.first.isDone)
                assertFalse("Death alone must not release the exit waiter", exited.isDone)
                assertNotNull(f.handshakeFailure())
                assertEquals(1, f.bindCount)
                release.countDown()
                assertNotNull(document.first.get(5, TimeUnit.SECONDS))
                assertNull(exited.get(5, TimeUnit.SECONDS))
                assertEquals(1, f.exitReplyCount.get())
            } finally {
                release.countDown()
                executor.shutdown()
                try { assertTrue("Document read executor drains", executor.awaitTermination(10, TimeUnit.SECONDS)) }
                finally { f.onState { ioField.set(f.client, previous) } }
            }
        }
    }

    @Test fun presentationRefreshClearsUnavailableSystemFlagsWithoutStartingAnotherCore() {
        Fixture().use { f ->
            for (connected in listOf(true, false)) {
                f.accept(f.ready().apply { putBoolean("alwaysOn", true); putBoolean("lockdown", true) }).get(5, TimeUnit.SECONDS)
                if (!connected) f.disconnect()
                assertNull(f.refresh())
                assertNull(f.client.status()["alwaysOn"])
                assertNull(f.client.status()["lockdown"])
            }
        }
    }

    @Test fun recoveryNoticeUsesApplicationLanguageAndDismissalSurvivesRefresh() {
        Fixture().use { f ->
            val manager = f.context.getSystemService(android.app.NotificationManager::class.java)
            org.junit.Assume.assumeTrue("Notifications must already be enabled", manager.areNotificationsEnabled())
            assertFalse("Do not replace an existing recovery notice", manager.activeNotifications.any { it.id == 5 })
            val strings = io.github.monadboxlab.clashpseudo.message.AppStrings
            val directory = java.io.File(f.context.cacheDir, "recovery-language-${UUID.randomUUID()}")
            assertTrue(directory.mkdir())
            val context = object : android.content.ContextWrapper(f.context) {
                override fun getApplicationContext(): android.content.Context = this
                override fun getFilesDir(): java.io.File = directory
            }
            val stores = AppFiles.configs(context)
            val storage = io.github.monadboxlab.clashpseudo.backup.BackupFiles(
                stores.canonicalFile, java.io.File(directory, "backup").canonicalFile).transaction
            val platformStorage = io.github.monadboxlab.clashpseudo.backup.BackupFiles.get(f.context).transaction
            val platformEpoch = platformStorage.snapshot().epoch
            val instrumentation = InstrumentationRegistry.getInstrumentation()
            try {
                platformStorage.requireEpoch(platformEpoch)
                val epoch = storage.recover().epoch
                val lease = io.github.monadboxlab.clashpseudo.backup.BackupLease()
                fun saveLanguage(language: String) {
                    storage.requireEpoch(epoch)
                    java.io.File(stores, "preferences.json.tmp").writeText(JSONObject().put("language", language).toString())
                    val publication = storage.publishStore(
                        io.github.monadboxlab.clashpseudo.backup.BackupFiles.Kind.PREFERENCES, epoch, lease)
                    assertTrue(publication.toString(), publication.saved && publication.durable)
                    instrumentation.runOnMainSync {
                        platformStorage.requireEpoch(platformEpoch)
                        storage.requireEpoch(epoch)
                        strings.refresh(context)
                    }
                    assertEquals(language, strings.language)
                }
                saveLanguage("en")
                f.client.publishRecoveryNotice()
                CorePlatformTestDriver(f.context).await("Recovery notice is published") { manager.activeNotifications.any { it.id == 5 } }
                saveLanguage("zh")
                assertNull(f.refresh())
                CorePlatformTestDriver(f.context).await("Recovery notice uses the new application language") {
                    manager.activeNotifications.singleOrNull { it.id == 5 }?.notification?.extras
                        ?.getString(android.app.Notification.EXTRA_TITLE) == strings.get(io.github.monadboxlab.clashpseudo.R.string.core_recovery_title)
                }
                val notice = manager.activeNotifications.single { it.id == 5 }.notification
                assertEquals(strings.get(io.github.monadboxlab.clashpseudo.R.string.core_recovery_body),
                    notice.extras.getString(android.app.Notification.EXTRA_TEXT))
                if (android.os.Build.VERSION.SDK_INT >= 26) assertEquals(
                    strings.get(io.github.monadboxlab.clashpseudo.R.string.core_recovery_channel),
                    manager.getNotificationChannel("core-recovery").name.toString())
                manager.cancel(5)
                CorePlatformTestDriver(f.context).await("Recovery notice is dismissed") { manager.activeNotifications.none { it.id == 5 } }
                saveLanguage("en")
                assertNull(f.refresh())
                assertTrue(manager.activeNotifications.none { it.id == 5 })
            } finally {
                manager.cancel(5)
                try {
                    instrumentation.runOnMainSync {
                        strings.initialize(f.context)
                        strings.refresh(f.context)
                    }
                } finally { assertTrue(directory.deleteRecursively()) }
            }
        }
    }

    @Test fun lateSnapshotFrameCannotOverwriteStoppingStatusOrRestoreBoundRows() {
        Fixture().use { f ->
            val empty = f.details(f.ready(revision = 2), JSONArray())
            empty.second(); assertNull(empty.first.get(5, TimeUnit.SECONDS))
            val stale = JSONObject().put("listeners", JSONArray().put(JSONObject().put("name", "old").put("state", "bound")))
                .put("platform", JSONObject().put("vpn", JSONObject().put("running", true))
                    .put("lan", JSONObject().put("running", true)))
                .put("processId", f.processId).put("inputId", f.inputId).put("generation", 1).put("networkRevision", 7)
                .put(Contract.CORE_FIELD_LISTENER_REVISION, 1)
            f.readSnapshot(stale) {
                f.accept(f.ready(revision = 2).apply {
                    putString("phase", Contract.CORE_PHASE_STOPPING); putBoolean("vpnRunning", false); putBoolean("lanRunning", false)
                }).get(5, TimeUnit.SECONDS)
            }
            assertEquals(Contract.CORE_PHASE_STOPPING, f.client.status()["phase"])
            assertEquals(false, f.client.status()["vpnRunning"])
            assertEquals(false, f.client.status()["lanRunning"])
            assertEquals(emptyList<Any>(), f.client.status()["lanListeners"])
        }
    }

    @Test fun fullListenerDocumentsReplaceRowsAndRejectOlderRevisionAndStop() {
        Fixture().use { f ->
            val bound = JSONArray().put(JSONObject().put("name", "one").put("state", "bound"))
            val closed = JSONArray().put(JSONObject().put("name", "one").put("state", "closeFailed")
                .put("error", JSONObject().put("message", "close failed")))
            val old = f.details(f.ready(revision = 1), bound)
            val newer = f.details(f.ready(revision = 2), closed)
            newer.second(); assertNull(newer.first.get(5, TimeUnit.SECONDS))
            old.second(); assertNull(old.first.get(5, TimeUnit.SECONDS))
            val rows = f.client.status()["lanListeners"] as List<*>
            assertEquals("closeFailed", (rows.single() as Map<*, *>)["state"])
            val empty = f.details(f.ready(revision = 3), JSONArray())
            empty.second(); assertNull(empty.first.get(5, TimeUnit.SECONDS))
            assertEquals(emptyList<Any>(), f.client.status()["lanListeners"])
            val late = f.details(f.ready(revision = 4), bound)
            f.accept(f.ready(revision = 4).apply { putString("phase", Contract.CORE_PHASE_STOPPING) }).get(5, TimeUnit.SECONDS)
            late.second(); assertNull(late.first.get(5, TimeUnit.SECONDS))
            assertEquals(emptyList<Any>(), f.client.status()["lanListeners"])
            assertEquals(Contract.CORE_PHASE_STOPPING, f.client.status()["phase"])
        }
    }
}

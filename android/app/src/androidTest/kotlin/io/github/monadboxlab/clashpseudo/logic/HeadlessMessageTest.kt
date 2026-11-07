package io.github.monadboxlab.clashpseudo.logic

import io.github.monadboxlab.clashpseudo.storage.AppFiles
import io.github.monadboxlab.clashpseudo.message.AppMessage
import io.github.monadboxlab.clashpseudo.message.AppStrings
import io.github.monadboxlab.clashpseudo.app.PseudoApplication
import io.github.monadboxlab.clashpseudo.bridge.AppBridge
import io.github.monadboxlab.clashpseudo.backup.BackupFiles
import io.github.monadboxlab.clashpseudo.backup.BackupLease
import io.github.monadboxlab.clashpseudo.backup.RestoreTransaction

import android.content.Context
import android.content.ContextWrapper
import android.content.res.Configuration
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineGroup
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.monadboxlab.clashpseudo.R
import io.github.monadboxlab.clashpseudo.vpn.NativeSession
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import java.io.File
import java.util.Locale
import java.util.UUID
import java.util.concurrent.CancellationException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutionException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class HeadlessMessageTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val application get() = instrumentation.targetContext.applicationContext as PseudoApplication
    private fun main(action: () -> Unit) = instrumentation.runOnMainSync(action)

    private fun languageContext(locale: Locale): Context = object : ContextWrapper(
        application.createConfigurationContext(Configuration(application.resources.configuration).apply {
            setLocale(locale)
        })
    ) {
        override fun getApplicationContext(): Context = this
    }

    @Test
    fun systemLanguageFollowsConfigurationChanges() {
        val english = languageContext(Locale.ENGLISH)
        val chinese = languageContext(Locale.SIMPLIFIED_CHINESE)
        try {
            main { AppStrings.initialize(english) }
            assertEquals(english.getString(R.string.error_busy), AppStrings.get(R.string.error_busy))
            main { AppStrings.configurationChanged(chinese) }
            assertEquals("system", AppStrings.language)
            assertEquals(chinese.getString(R.string.error_busy), AppStrings.get(R.string.error_busy))
            main { AppStrings.configurationChanged(english) }
            assertEquals(english.getString(R.string.error_busy), AppStrings.get(R.string.error_busy))
        } finally {
            main {
                AppStrings.initialize(application)
                AppStrings.refresh(application)
            }
        }
    }

    @Test
    fun recreatedEnginesReturnDescriptionsAndNativeDisplayUsesSavedLanguage() {
        val fixture = File(application.cacheDir, "headless-messages-${UUID.randomUUID()}")
        assertTrue(fixture.mkdir())
        val context = object : ContextWrapper(application) {
            override fun getApplicationContext(): Context = this
            override fun getFilesDir(): File = fixture
        }
        val directory = AppFiles.configs(context)
        val worker = Executors.newSingleThreadExecutor()
        val enginesReleased = AtomicBoolean(true)
        val callbackFailure = AtomicReference<Throwable?>()
        var failure: Throwable? = null
        try {
            val manager = androidx.work.WorkManager.getInstance(instrumentation.targetContext)
            val startupDeadline = android.os.SystemClock.elapsedRealtime() + 45_000
            while (true) {
                var idle = false
                var facts = ""
                main {
                    val runtime = AppBridge.runtimeState()
                    idle = AppBridge.operationId == null && !AppBridge.logic.busy &&
                        !AppBridge.pendingSystemRestore && runtime["writerBusy"] == false &&
                        runtime["storageReady"] == true && runtime["storageRestoring"] != true
                    val runtimeFacts = listOf("phase", "storageReady", "storageRestoring", "storageEpoch",
                        "writerBusy", "scheduleBusy", "resourceBusy", "pendingRestore", "pendingSystemStart")
                        .associateWith { runtime[it] }
                    facts = "operationId=${AppBridge.operationId}, action=${AppBridge.command?.get("action")}, " +
                        "logicBusy=${AppBridge.logic.busy}, runtime=$runtimeFacts"
                }
                val work = try {
                    manager.getWorkInfosForUniqueWork("update-reconcile").get(5, TimeUnit.SECONDS)
                } catch (error: Exception) {
                    throw IllegalStateException("Startup WorkInfo query failed: $facts", error)
                }
                if (work.isNotEmpty() && work.all { it.state.isFinished } && idle) break
                check(android.os.SystemClock.elapsedRealtime() < startupDeadline) {
                    "Startup reconciliation did not drain: $facts; work=" +
                        work.map { "${it.id}:${it.state}:attempt=${it.runAttemptCount}" }
                }
                android.os.SystemClock.sleep(20)
            }
            main {
                assertNull(AppBridge.operationId)
                assertEquals(NativeSession.Phase.STOPPED, PseudoVpnService.session.snapshot().phase)
            }
            val files = BackupFiles(directory.canonicalFile, File(fixture, "backup").canonicalFile)
            val storage = files.transaction
            val recovered = try {
                worker.submit<RestoreTransaction.State> { storage.recover() }.get(10, TimeUnit.SECONDS)
            } catch (error: ExecutionException) {
                throw error.cause ?: error
            }
            val epoch = recovered.epoch
            storage.requireEpoch(epoch)
            val first = executeInNewEngine(context, directory, "en", storage, epoch, worker, enginesReleased, callbackFailure)
            assertEquals("first=$first", true, first["success"])
            assertEquals("first=$first", AppMessage("settingsSaved"), AppMessage.fromMap(first["message"]))
            assertEquals("first=$first", "en", JSONObject(File(directory, "preferences.json").readText()).getString("language"))
            main { AppStrings.configurationChanged(languageContext(Locale.SIMPLIFIED_CHINESE)) }
            assertEquals(
                "first=$first",
                application.createConfigurationContext(Configuration(application.resources.configuration).apply {
                    setLocale(Locale.ENGLISH)
                }).getString(R.string.error_busy),
                AppStrings.get(R.string.error_busy)
            )
            val description = AppStrings.message(R.string.error_busy)
            val recreated = executeInNewEngine(context, directory, "zh", storage, epoch, worker, enginesReleased, callbackFailure)
            assertEquals("first=$first; recreated=$recreated", true, recreated["success"])
            assertEquals("first=$first; recreated=$recreated", first["message"], recreated["message"])
            assertEquals("first=$first; recreated=$recreated", "zh", JSONObject(File(directory, "preferences.json").readText()).getString("language"))
            assertEquals("first=$first; recreated=$recreated", description, AppStrings.message(R.string.error_busy))
            main { AppStrings.configurationChanged(languageContext(Locale.ENGLISH)) }
            assertEquals(
                "first=$first; recreated=$recreated",
                application.createConfigurationContext(Configuration(application.resources.configuration).apply {
                    setLocale(Locale.SIMPLIFIED_CHINESE)
                }).getString(R.string.error_busy),
                AppStrings.get(R.string.error_busy)
            )
            main {
                assertNull(AppBridge.operationId)
                assertEquals(NativeSession.Phase.STOPPED, PseudoVpnService.session.snapshot().phase)
            }
        } catch (error: Throwable) {
            failure = error
        } finally {
            var drained = false
            try {
                worker.shutdown()
                drained = worker.awaitTermination(10, TimeUnit.SECONDS)
                check(drained) { "Headless publication worker did not drain; fixture retained: $fixture" }
            } catch (error: Throwable) {
                failure = preserveFailure(failure, error)
            } finally {
                callbackFailure.get()?.let { failure = preserveFailure(failure, it) }
                try {
                    main {}
                } catch (error: Throwable) {
                    failure = preserveFailure(failure, error)
                } finally {
                    try {
                        main { AppStrings.initialize(application) }
                    } catch (error: Throwable) {
                        failure = preserveFailure(failure, error)
                    }
                    if (drained && enginesReleased.get()) {
                        try {
                            assertTrue(fixture.deleteRecursively())
                        } catch (error: Throwable) {
                            failure = preserveFailure(failure, error)
                        }
                    }
                }
            }
        }
        failure?.let { throw it }
    }

    private fun preserveFailure(first: Throwable?, next: Throwable): Throwable {
        if (first == null) return next
        if (first !== next) first.addSuppressed(next)
        return first
    }

    private fun executeInNewEngine(
        context: Context,
        directory: File,
        language: String,
        storage: RestoreTransaction,
        epoch: Long,
        worker: ExecutorService,
        enginesReleased: AtomicBoolean,
        callbackFailure: AtomicReference<Throwable?>,
    ): Map<*, *> {
        val owner = "message-$language"
        val lease = BackupLease()
        val ready = CountDownLatch(1)
        val completed = CountDownLatch(1)
        val outcome = AtomicReference<Map<*, *>?>()
        val failure = AtomicReference<Triple<String, String?, Any?>?>()
        var engine: FlutterEngine? = null
        var channel: MethodChannel? = null
        var attached = false
        var actual: Map<*, *>? = null
        var primary: Throwable? = null
        fun checkCall(call: MethodCall) {
            if (call.argument<String>("owner") != owner) {
                throw CancellationException("Headless engine owner changed")
            }
            lease.checkCurrent()
            storage.requireEpoch(epoch)
        }
        fun reject(result: MethodChannel.Result, error: Throwable) {
            val expired = error is CancellationException
            result.error(if (expired) "expired" else "storage", null,
                AppMessage(if (expired) "operationFinished" else "storageUnavailable").withDetail(error).toMap())
        }
        try {
            main {
                val group = application.engines
                val entry = DartExecutor.DartEntrypoint(
                    FlutterInjector.instance().flutterLoader().findAppBundlePath(), "appBackgroundMain"
                )
                val running = group.createAndRunEngine(
                    FlutterEngineGroup.Options(application).setDartEntrypoint(entry)
                        .setAutomaticallyRegisterPlugins(false)
                )
                engine = running
                val calls = MethodChannel(running.dartExecutor.binaryMessenger, AppBridge.CHANNEL)
                channel = calls
                attached = true
                calls.setMethodCallHandler { call, result ->
                    try {
                        when (call.method) {
                            "ready" -> { result.success(null); ready.countDown() }
                            "paths" -> {
                                checkCall(call)
                                result.success(mapOf(
                                    "configs" to directory.path,
                                    "runInput" to File(directory.parentFile, "input.json").path,
                                    "storageEpoch" to epoch,
                                ))
                            }
                            "checkOperation" -> { checkCall(call); result.success(null) }
                            "refreshStrings" -> {
                                checkCall(call)
                                AppStrings.refresh(context)
                                result.success(null)
                            }
                            "publishStore" -> {
                                checkCall(call)
                                require(call.argument<String>("file") == BackupFiles.Kind.PREFERENCES.fileName) {
                                    "Headless fixture only publishes preferences.json"
                                }
                                val rawEpoch = call.argument<Any>("epoch")
                                require(rawEpoch is Int || rawEpoch is Long) { "Invalid publication epoch" }
                                require((rawEpoch as Number).toLong() == epoch) { "Publication epoch changed" }
                                worker.execute {
                                    val publication = runCatching {
                                        checkCall(call)
                                        storage.publishStore(BackupFiles.Kind.PREFERENCES, epoch, lease)
                                    }
                                    try {
                                        main {
                                            if (attached) publication.fold(
                                                onSuccess = { value ->
                                                    result.success(mapOf(
                                                        "saved" to value.saved,
                                                        "durable" to value.durable,
                                                        "epoch" to value.epoch,
                                                        "errorCode" to value.error,
                                                        "errorDetail" to value.cause?.let {
                                                            AppMessage("storageUnavailable").withDetail(it).toMap()
                                                        },
                                                    ))
                                                },
                                                onFailure = { error -> reject(result, error) },
                                            )
                                        }
                                    } catch (error: Throwable) {
                                        callbackFailure.set(preserveFailure(callbackFailure.get(), error))
                                        completed.countDown()
                                    }
                                }
                            }
                            else -> result.notImplemented()
                        }
                    } catch (error: Throwable) {
                        reject(result, error)
                    }
                }
            }
            assertTrue("Headless engine did not become ready", ready.await(20, TimeUnit.SECONDS))
            main {
                checkNotNull(channel).invokeMethod("execute", mapOf(
                    "owner" to owner,
                    "action" to "setPreference",
                    "field" to "language",
                    "value" to language
                ), object : MethodChannel.Result {
                    override fun success(result: Any?) { outcome.set(result as? Map<*, *>); completed.countDown() }
                    override fun error(code: String, message: String?, details: Any?) {
                        failure.set(Triple(code, message, details))
                        completed.countDown()
                    }
                    override fun notImplemented() { failure.set(Triple("missing", null, null)); completed.countDown() }
                })
            }
            assertTrue("Headless engine did not return its result", completed.await(20, TimeUnit.SECONDS))
            callbackFailure.get()?.let { throw it }
            assertNull("Headless engine error (code, message, details): ${failure.get()}", failure.get())
            actual = requireNotNull(outcome.get())
        } catch (error: Throwable) {
            primary = error
        } finally {
            try {
                lease.cancel()
            } catch (error: Throwable) {
                primary = preserveFailure(primary, error)
            }
            try {
                main { attached = false; channel?.setMethodCallHandler(null) }
            } catch (error: Throwable) {
                primary = preserveFailure(primary, error)
            }
            try {
                main { engine?.destroy() }
            } catch (error: Throwable) {
                enginesReleased.set(false)
                primary = preserveFailure(primary, error)
            }
        }
        primary?.let { throw it }
        return requireNotNull(actual)
    }
}

package io.github.monadboxlab.clashpseudo.logic

import io.github.monadboxlab.clashpseudo.app.AppFiles
import io.github.monadboxlab.clashpseudo.app.AppMessage
import io.github.monadboxlab.clashpseudo.app.AppStrings
import io.github.monadboxlab.clashpseudo.app.PseudoApplication
import io.github.monadboxlab.clashpseudo.bridge.AppBridge

import android.content.Context
import android.content.ContextWrapper
import android.content.res.Configuration
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineGroup
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.github.monadboxlab.clashpseudo.R
import io.github.monadboxlab.clashpseudo.vpn.NativeSession
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import java.io.File
import java.util.Locale
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class HeadlessMessageTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val application get() = instrumentation.targetContext.applicationContext as PseudoApplication
    private fun main(action: () -> Unit) = instrumentation.runOnMainSync(action)

    @Test
    fun recreatedEnginesReturnDescriptionsAndNativeDisplayUsesSavedLanguage() {
        val fixture = File(application.cacheDir, "headless-messages-${UUID.randomUUID()}")
        assertTrue(fixture.mkdir())
        val context = object : ContextWrapper(application) {
            override fun getApplicationContext(): Context = this
            override fun getFilesDir(): File = fixture
        }
        val directory = AppFiles.configs(context)
        try {
            main {
                assertNull(AppBridge.operationId)
                assertEquals(NativeSession.Phase.STOPPED, PseudoVpnService.session.snapshot().phase)
            }
            val first = executeInNewEngine(context, directory, "en")
            assertEquals(true, first["success"])
            assertEquals(AppMessage("settingsSaved"), AppMessage.fromMap(first["message"]))
            assertEquals("en", JSONObject(File(directory, "preferences.json").readText()).getString("language"))
            assertEquals(
                application.createConfigurationContext(Configuration(application.resources.configuration).apply {
                    setLocale(Locale.ENGLISH)
                }).getString(R.string.error_busy),
                AppStrings.get(R.string.error_busy)
            )
            val description = AppStrings.message(R.string.error_busy)
            val recreated = executeInNewEngine(context, directory, "zh")
            assertEquals(true, recreated["success"])
            assertEquals(first["message"], recreated["message"])
            assertEquals("zh", JSONObject(File(directory, "preferences.json").readText()).getString("language"))
            assertEquals(description, AppStrings.message(R.string.error_busy))
            assertEquals(
                application.createConfigurationContext(Configuration(application.resources.configuration).apply {
                    setLocale(Locale.SIMPLIFIED_CHINESE)
                }).getString(R.string.error_busy),
                AppStrings.get(R.string.error_busy)
            )
            main {
                assertNull(AppBridge.operationId)
                assertEquals(NativeSession.Phase.STOPPED, PseudoVpnService.session.snapshot().phase)
            }
        } finally {
            main { AppStrings.initialize(application) }
            assertTrue(fixture.deleteRecursively())
        }
    }

    private fun executeInNewEngine(context: Context, directory: File, language: String): Map<*, *> {
        val ready = CountDownLatch(1)
        val completed = CountDownLatch(1)
        val outcome = AtomicReference<Map<*, *>?>()
        val failure = AtomicReference<String?>()
        lateinit var engine: FlutterEngine
        lateinit var channel: MethodChannel
        main {
            val group = application.engines
            val entry = DartExecutor.DartEntrypoint(
                FlutterInjector.instance().flutterLoader().findAppBundlePath(), "appBackgroundMain"
            )
            engine = group.createAndRunEngine(
                FlutterEngineGroup.Options(application).setDartEntrypoint(entry)
                    .setAutomaticallyRegisterPlugins(false)
            )
            channel = MethodChannel(engine.dartExecutor.binaryMessenger, AppBridge.CHANNEL)
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "ready" -> { result.success(null); ready.countDown() }
                    "paths" -> result.success(mapOf(
                        "configs" to directory.path,
                        "runInput" to File(directory.parentFile, "input.json").path
                    ))
                    "checkOperation" -> result.success(null)
                    "refreshStrings" -> { AppStrings.refresh(context); result.success(null) }
                    else -> result.notImplemented()
                }
            }
        }
        try {
            assertTrue("Headless engine did not become ready", ready.await(20, TimeUnit.SECONDS))
            main {
                channel.invokeMethod("execute", mapOf(
                    "owner" to "message-$language",
                    "action" to "setPreference",
                    "field" to "language",
                    "value" to language
                ), object : MethodChannel.Result {
                    override fun success(result: Any?) { outcome.set(result as? Map<*, *>); completed.countDown() }
                    override fun error(code: String, message: String?, details: Any?) { failure.set(code); completed.countDown() }
                    override fun notImplemented() { failure.set("missing"); completed.countDown() }
                })
            }
            assertTrue("Headless engine did not return its result", completed.await(20, TimeUnit.SECONDS))
            assertNull(failure.get())
            return requireNotNull(outcome.get())
        } finally {
            main { channel.setMethodCallHandler(null); engine.destroy() }
        }
    }
}

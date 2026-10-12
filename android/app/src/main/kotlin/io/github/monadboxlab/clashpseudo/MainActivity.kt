package io.github.monadboxlab.clashpseudo

import android.content.Context
import android.content.Intent
import android.net.VpnService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.github.monadboxlab.clashpseudo.app.AppBridge
import io.github.monadboxlab.clashpseudo.app.PseudoApplication

class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine =
        (application as PseudoApplication).engines.createAndRunDefaultEngine(context)

    // Externally supplied engines otherwise default to outliving the Activity.
    override fun shouldDestroyEngineWithHost() = true

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        AppBridge.attachUi(this, flutterEngine)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        AppBridge.detachUi(this)
        super.cleanUpFlutterEngine(flutterEngine)
    }

    fun requestVpnPermission(requestCode: Int) {
        val permission = VpnService.prepare(this)
        if (permission == null) AppBridge.authorizationResult(requestCode, true)
        else try { startActivityForResult(permission, requestCode) }
        catch (_: Exception) { AppBridge.authorizationResult(requestCode, false) }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        AppBridge.authorizationResult(requestCode, resultCode == RESULT_OK)
    }

    override fun onResume() {
        super.onResume()
        AppBridge.notifyUi()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        AppBridge.notifyUi()
    }
}

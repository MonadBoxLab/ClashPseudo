package io.github.monadboxlab.clashpseudo

import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.github.monadboxlab.clashpseudo.bridge.AppBridge
import io.github.monadboxlab.clashpseudo.app.PseudoApplication
import io.github.monadboxlab.clashpseudo.controls.SystemControls

class MainActivity : FlutterActivity() {
    private var shortcutAllowed = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        AppBridge.restoreActivityState(savedInstanceState)
        AppBridge.attachBackupActivity(this, savedInstanceState)
        shortcutAllowed = savedInstanceState == null
    }

    override fun onSaveInstanceState(outState: Bundle) {
        AppBridge.saveActivityState(outState)
        AppBridge.saveBackupActivityState(this, outState)
        super.onSaveInstanceState(outState)
    }

    override fun onPostResume() {
        super.onPostResume()
        val allowed = shortcutAllowed
        shortcutAllowed = false
        if (SystemControls.consumeOverviewIntent(this, allowed)) {
            AppBridge.requestOverview()
            return
        }
        val action = SystemControls.consumeActivityIntent(this, allowed) ?: return
        SystemControls.request(this, action) { admission ->
            if (admission == SystemControls.Admission.VPN_SETTINGS && !isFinishing && !isDestroyed) {
                try { startActivity(SystemControls.settingsIntent(this)) }
                catch (_: Exception) { AppBridge.notifyUi() }
            }
            // OPEN_APP is handled by the visible Activity once.
            SystemControls.refresh(this)
        }
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine =
        (application as PseudoApplication).engines.createAndRunDefaultEngine(context)

    // Externally supplied engines otherwise default to outliving the Activity.
    override fun shouldDestroyEngineWithHost() = true

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        AppBridge.attachUi(this, flutterEngine)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        AppBridge.detachBackupActivity(this)
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
        if (AppBridge.backupActivityResult(this, requestCode, resultCode, data)) return
        super.onActivityResult(requestCode, resultCode, data)
        AppBridge.authorizationResult(requestCode, resultCode == RESULT_OK)
    }

    override fun onStart() {
        super.onStart()
        AppBridge.setUiVisible(this, true)
    }

    override fun onStop() {
        AppBridge.setUiVisible(this, false)
        super.onStop()
    }

    override fun onResume() {
        super.onResume()
        AppBridge.notifyUi()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        shortcutAllowed = true
        AppBridge.notifyUi()
    }
}

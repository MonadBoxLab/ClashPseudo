package io.github.monadboxlab.clashpseudo.app

import io.github.monadboxlab.clashpseudo.backup.BackupFiles
import io.github.monadboxlab.clashpseudo.bridge.AppBridge
import io.github.monadboxlab.clashpseudo.controls.SystemControls
import io.github.monadboxlab.clashpseudo.schedule.ScheduleManager

import android.app.Application
import android.content.res.Configuration
import android.os.Handler
import android.util.Log
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngineGroup
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService

class PseudoApplication : Application() {
    val engines by lazy { FlutterEngineGroup(this) }

    override fun onCreate() {
        super.onCreate()
        AppStrings.initialize(this)
        AppBridge.initialize(this)
        val main = Handler(Looper.getMainLooper())
        PseudoVpnService.session.changed = { main.post { AppBridge.nativeChanged() } }
        // Recovery precedes every business-file consumer. The UI can attach
        // while this worker runs, but the bridge keeps its storage paths closed.
        BackupFiles.get(this).ioExecutor.execute {
            val recovered = runCatching { BackupFiles.get(this).transaction.recover() }
            main.post {
                if (recovered.getOrNull()?.ready == true) AppStrings.refresh(this)
                AppBridge.notifyUi()
            }
            if (recovered.getOrNull()?.ready == true) {
                // Release the storage lane before waiting for schedule reconciliation,
                // which may itself use that lane.
                Thread { runCatching { ScheduleManager.reconcile(this) } }.start()
            } else {
                Log.w("PseudoStorage", "Business storage recovery is unavailable")
            }
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        try {
            AppStrings.refresh(this)
        } catch (_: Exception) {
            Log.w("PseudoStrings", "Unable to refresh display language")
            return
        }
        try {
            PseudoVpnService.instance?.refreshNotification()
        } catch (_: Exception) {
            Log.w("PseudoStrings", "Unable to refresh VPN notification")
        }
        try {
            AppWorkService.instance?.refreshNotification()
        } catch (_: Exception) {
            Log.w("PseudoStrings", "Unable to refresh work notification")
        }
        SystemControls.refresh(this)
    }
}

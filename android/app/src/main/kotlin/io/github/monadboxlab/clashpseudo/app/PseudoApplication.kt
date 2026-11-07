package io.github.monadboxlab.clashpseudo.app

import io.github.monadboxlab.clashpseudo.message.AppStrings
import io.github.monadboxlab.clashpseudo.storage.AppFiles
import io.github.monadboxlab.clashpseudo.storage.CoreDataCleanup

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
    val engines by lazy {
        AppProcess.requireApplication(this)
        FlutterEngineGroup(this)
    }

    override fun onCreate() {
        super.onCreate()
        AppStrings.initialize(this)
        if (AppProcess.isCore(this)) return
        AppProcess.requireApplication(this)
        io.github.monadboxlab.clashpseudo.nativecore.CoreClient.get(this)
        AppBridge.initialize(this)
        val main = Handler(Looper.getMainLooper())
        // Recovery precedes every business-file consumer. The UI can attach
        // while this worker runs, but the bridge keeps its storage paths closed.
        BackupFiles.get(this).ioExecutor.execute {
            val files = BackupFiles.get(this)
            val recovered = runCatching {
                files.transaction.recover { files.cleanupOrphans(AppFiles.work(this), AppFiles.core(this)) }
            }
            val cleanup = CoreDataCleanup.get(this)
            cleanup.initialize()
            if (cleanup.ready && io.github.monadboxlab.clashpseudo.nativecore.CoreClient.get(this).lifecycle.snapshot().cleanupPending) {
                try { io.github.monadboxlab.clashpseudo.nativecore.CoreClient.get(this).lifecycle.cleanup(false) }
                catch (error: Throwable) { Log.w("PseudoStorage", "Failed to save file cleanup state", error) }
            }
            main.post {
                if (recovered.getOrNull()?.ready == true) AppStrings.refresh(this)
                AppBridge.notifyUi()
            }
            if (recovered.getOrNull()?.ready == true) {
                // Release the file I/O executor before waiting for schedule reconciliation,
                // which may submit work to the same executor.
                Thread { runCatching { ScheduleManager.reconcile(this) } }.start()
            } else {
                Log.w("PseudoStorage", "Business storage recovery is unavailable", recovered.exceptionOrNull())
            }
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (AppProcess.isCore(this)) {
            AppStrings.initialize(this)
            PseudoVpnService.instance?.refreshNotification()
            io.github.monadboxlab.clashpseudo.nativecore.CoreService.instance?.refreshNotification()
            return
        }
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

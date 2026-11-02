package io.github.monadboxlab.clashpseudo.controls

import io.github.monadboxlab.clashpseudo.message.AppStrings
import io.github.monadboxlab.clashpseudo.app.VpnTileService
import io.github.monadboxlab.clashpseudo.app.VpnWidgetProvider
import io.github.monadboxlab.clashpseudo.bridge.AppBridge

import android.app.Activity
import android.app.ActivityOptions
import android.app.KeyguardManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.service.quicksettings.TileService
import android.util.Log
import io.github.monadboxlab.clashpseudo.MainActivity
import io.github.monadboxlab.clashpseudo.R

/** SDK entry points project state; AppBridge remains the sole operation admission. */
object SystemControls {
    enum class Admission { ACCEPTED, UNCHANGED, OPEN_APP, VPN_SETTINGS }
    enum class ModeSource { ACTUAL, SAVED, CONFIGURATION, UNKNOWN }

    data class Projection(
        val phase: String,
        val mode: String?,
        val savedMode: String?,
        val savedModeKnown: Boolean,
        val busy: Boolean,
        val failed: Boolean,
        val pendingStart: Boolean,
        val pendingSystemStart: Boolean,
        val pendingRestore: Boolean = false,
    ) {
        val preparing: Boolean get() = pendingStart || pendingSystemStart || phase == "STARTING"
        // Carries the explicit action rendered by this projection.
        val action: String? get() = when {
            pendingRestore -> "stop"
            phase == "STOPPING" -> null
            preparing || phase == "RUNNING" -> "stop"
            phase == "STOPPED" -> "start"
            else -> null
        }
        val enabled: Boolean get() = action == "stop" || (action == "start" && !busy)
        // A busy stopped tile keeps its open-app action available while preparation is
        // queued.
        val tileEnabled: Boolean get() = pendingRestore || phase in setOf("STOPPED", "STARTING", "RUNNING") ||
            (preparing && phase != "STOPPING")
        val modeSource: ModeSource get() = when {
            phase == "RUNNING" && mode != null -> ModeSource.ACTUAL
            phase != "STOPPED" -> ModeSource.UNKNOWN
            !savedModeKnown -> ModeSource.UNKNOWN
            savedMode != null -> ModeSource.SAVED
            else -> ModeSource.CONFIGURATION
        }
        val statusResource: Int get() = when {
            pendingRestore -> R.string.system_control_restoring
            phase == "STOPPING" -> R.string.system_control_stopping
            preparing -> R.string.system_control_starting
            phase == "RUNNING" -> R.string.system_control_connected
            phase != "STOPPED" -> R.string.system_control_unknown
            failed -> R.string.system_control_failed
            busy -> R.string.system_control_busy
            else -> R.string.system_control_stopped
        }
    }

    private val main by lazy { Handler(Looper.getMainLooper()) }
    private var refreshQueued = false
    private val widgetRead = RefreshRead()
    private var shortcutLabels: Pair<String, String>? = null
    private val modes = setOf("rule", "global", "direct")

    /** Release the main-thread read gate on actual completion. */
    internal class RefreshRead {
        private var inFlight = false
        private var dirty = false

        fun request(): Boolean {
            if (inFlight) { dirty = true; return false }
            inFlight = true
            return true
        }

        fun complete(): Boolean {
            check(inFlight)
            if (dirty) { dirty = false; return true }
            inFlight = false
            return false
        }
    }

    const val ACTION_OPEN_OVERVIEW = "io.github.monadboxlab.clashpseudo.OPEN_OVERVIEW"

    internal fun overviewRequested(action: String?, restored: Boolean, fromHistory: Boolean): Boolean =
        action == ACTION_OPEN_OVERVIEW && !restored && !fromHistory

    internal fun shortcutAction(
        packageName: String,
        componentPackage: String?,
        componentClass: String?,
        restored: Boolean,
        fromHistory: Boolean,
    ): String? {
        if (restored || fromHistory || componentPackage != packageName) return null
        return when (componentClass) {
            "$packageName.StartVpnShortcut" -> "start"
            "$packageName.StopVpnShortcut" -> "stop"
            else -> null
        }
    }

    internal fun project(value: Map<String, Any?>): Projection {
        val phase = (value["phase"] as? String)
            ?.takeIf { it in setOf("STOPPED", "STARTING", "RUNNING", "STOPPING", "UNKNOWN") }
            ?: "UNKNOWN"
        val saved = value["savedMode"]
        val savedKnown = value["savedModeKnown"] == true &&
            (saved == null || saved is String && saved in modes)
        return Projection(
            phase = phase,
            mode = (value["mode"] as? String)?.takeIf { it in modes },
            savedMode = (saved as? String)?.takeIf { savedKnown && it in modes },
            savedModeKnown = savedKnown,
            busy = value["busy"] != false || value["pendingRestore"] == true,
            failed = value["failed"] == true,
            pendingStart = value["pendingStart"] == true,
            pendingSystemStart = value["pendingSystemStart"] == true,
            pendingRestore = value["pendingRestore"] == true,
        )
    }

    fun snapshot(reply: (Projection) -> Unit) = AppBridge.systemControlSnapshot { reply(project(it)) }

    // An explicit Stop only reduces takeover and must preserve the latest user
    // intent even under keyguard. Start/navigation still need an unlocked user.
    internal fun requiresUnlock(action: String?): Boolean = action != "stop"

    fun request(context: Context, action: String, reply: (Admission) -> Unit) {
        if (action !in setOf("start", "stop")) { reply(Admission.OPEN_APP); return }
        if (requiresUnlock(action)) {
            val unlocked = runCatching {
                context.getSystemService(KeyguardManager::class.java)?.isKeyguardLocked == false
            }.getOrDefault(false)
            if (!unlocked) { reply(Admission.OPEN_APP); return }
        }
        AppBridge.submitSystemControl(action, reply)
    }

    /** Coalesce refresh events through the existing read path. */
    fun refresh(context: Context) {
        val app = context.applicationContext
        if (Looper.myLooper() != Looper.getMainLooper()) {
            main.post { refresh(app) }
            return
        }
        if (refreshQueued) return
        refreshQueued = true
        main.post {
            refreshQueued = false
            refreshShortcuts(app)
            try {
                if (!VpnTileService.refreshListening()) {
                    TileService.requestListeningState(app, ComponentName(app, VpnTileService::class.java))
                }
            } catch (_: Exception) {
                Log.w("PseudoControls", "Unable to request tile state refresh")
            }
            if (widgetRead.request()) readWidget(app)
        }
    }

    private fun readWidget(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        if (manager.getAppWidgetIds(ComponentName(context, VpnWidgetProvider::class.java)).isEmpty()) {
            if (widgetRead.complete()) readWidget(context)
            return
        }
        snapshot { value ->
            try {
                VpnWidgetProvider.update(context, value)
            } catch (_: Exception) {
                Log.w("PseudoControls", "Unable to update widget state")
            } finally {
                // Events received while this actual read ran become only one subsequent read.
                if (widgetRead.complete()) readWidget(context)
            }
        }
    }

    private fun refreshShortcuts(context: Context) {
        if (Build.VERSION.SDK_INT < 25) return
        val labels = AppStrings.get(R.string.system_control_connect) to
            AppStrings.get(R.string.system_control_disconnect)
        if (shortcutLabels == labels) return
        try {
            val manager = context.getSystemService(ShortcutManager::class.java) ?: return
            val shortcuts = listOf("start", "stop").mapIndexed { index, action ->
                ShortcutInfo.Builder(context, "vpn-$action")
                    .setShortLabel(if (action == "start") labels.first else labels.second)
                    .setIcon(Icon.createWithResource(context, if (action == "start")
                        R.drawable.ic_control_connect else R.drawable.ic_control_disconnect))
                    .setIntent(actionIntent(context, action))
                    .setRank(index)
                    .build()
            }
            if (manager.setDynamicShortcuts(shortcuts)) shortcutLabels = labels
        } catch (_: Exception) {
            Log.w("PseudoControls", "Unable to update app shortcuts")
        }
    }

    fun openIntent(context: Context): Intent = Intent(context, MainActivity::class.java)
        .setAction(Intent.ACTION_MAIN)
        .addCategory(Intent.CATEGORY_LAUNCHER)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)

    /** Public navigation action for opening the application. */
    fun overviewIntent(context: Context): Intent = openIntent(context).setAction(ACTION_OPEN_OVERVIEW)

    fun consumeOverviewIntent(activity: Activity, allowed: Boolean): Boolean {
        val received = activity.intent ?: return false
        if (received.action != ACTION_OPEN_OVERVIEW) return false
        val requested = overviewRequested(received.action, restored = !allowed,
            fromHistory = received.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0)
        activity.intent = openIntent(activity)
        return requested
    }

    fun actionIntent(context: Context, action: String): Intent {
        require(action == "start" || action == "stop")
        return Intent(Intent.ACTION_MAIN)
            .setComponent(ComponentName(context.packageName, context.packageName +
                if (action == "start") ".StartVpnShortcut" else ".StopVpnShortcut"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
    }

    /** Validate the non-exported alias component before admitting an action. */
    fun consumeActivityIntent(activity: Activity, allowed: Boolean): String? {
        val received = activity.intent ?: return null
        val component = received.component
        val action = shortcutAction(activity.packageName, component?.packageName, component?.className,
            restored = !allowed,
            fromHistory = received.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0)
        if (component?.className in setOf(activity.packageName + ".StartVpnShortcut",
                activity.packageName + ".StopVpnShortcut")) {
            // Clear the launch record before admission/authorization can yield or recreate.
            activity.intent = openIntent(activity)
        }
        return action
    }

    fun settingsIntent(context: Context): Intent {
        val intent = Intent(Settings.ACTION_VPN_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val component = intent.resolveActivity(context.packageManager) ?: return openIntent(context)
        return intent.setComponent(component)
    }

    internal fun permissionResumeAction(action: String, admission: Admission, permissionRequired: Boolean): String? =
        if (action == "start" && admission == Admission.OPEN_APP && permissionRequired) "start" else null

    fun admissionIntent(context: Context, action: String, admission: Admission): Intent {
        if (admission == Admission.VPN_SETTINGS) return settingsIntent(context)
        val permissionRequired = action == "start" &&
            runCatching { VpnService.prepare(context) != null }.getOrDefault(false)
        val resume = permissionResumeAction(action, admission, permissionRequired)
        // A rejected command opens its existing error result.
        return if (resume != null) actionIntent(context, resume) else openIntent(context)
    }

    @Suppress("DEPRECATION")
    fun activityPendingIntent(context: Context, intent: Intent, requestCode: Int): PendingIntent {
        val options = if (Build.VERSION.SDK_INT >= 35) ActivityOptions.makeBasic()
            .setPendingIntentCreatorBackgroundActivityStartMode(ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED)
            .toBundle() else null
        return PendingIntent.getActivity(context, requestCode, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE, options)
    }

    @Suppress("DEPRECATION")
    fun openFromWidget(context: Context, action: String, admission: Admission) {
        val intent = admissionIntent(context, action, admission)
        val pending = activityPendingIntent(context, intent, if (admission == Admission.VPN_SETTINGS) 1041
            else if (action == "start") 1001 else 1002)
        try {
            val options = if (Build.VERSION.SDK_INT >= 34) ActivityOptions.makeBasic()
                .setPendingIntentBackgroundActivityStartMode(ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED)
                .toBundle() else null
            pending.send(context, 0, null, null, null, null, options)
        } catch (_: Exception) {
            Log.w("PseudoControls", "The system did not allow opening the app")
        }
    }

    fun modeText(value: Projection, context: Context? = null): String {
        fun text(id: Int) = context?.getString(id) ?: AppStrings.get(id)
        fun format(id: Int, mode: String) = context?.getString(id, mode) ?: AppStrings.format(id, mode)
        val mode = when (if (value.modeSource == ModeSource.ACTUAL) value.mode else value.savedMode) {
            "rule" -> text(R.string.system_control_mode_rule)
            "global" -> text(R.string.system_control_mode_global)
            "direct" -> text(R.string.system_control_mode_direct)
            else -> null
        }
        return when (value.modeSource) {
            ModeSource.ACTUAL -> format(R.string.system_control_mode_actual, mode!!)
            ModeSource.SAVED -> format(R.string.system_control_mode_saved, mode!!)
            ModeSource.CONFIGURATION -> text(R.string.system_control_mode_config)
            ModeSource.UNKNOWN -> text(R.string.system_control_mode_unknown)
        }
    }
}

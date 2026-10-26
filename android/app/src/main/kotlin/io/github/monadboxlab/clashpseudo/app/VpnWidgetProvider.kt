package io.github.monadboxlab.clashpseudo.app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.util.SizeF
import android.view.View
import android.widget.RemoteViews
import io.github.monadboxlab.clashpseudo.R
import io.github.monadboxlab.clashpseudo.controls.SystemControls
import kotlin.math.min
import kotlin.math.roundToInt

/** One square projection. Every rendered start/stop action is rechecked by the existing bridge. */
class VpnWidgetProvider : AppWidgetProvider() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = widgetAction(intent.action)
        if (action == null) {
            super.onReceive(context, intent)
            return
        }
        if (intent.component != ComponentName(context, VpnWidgetProvider::class.java)) return
        SystemControls.request(context, action) { admission ->
            if (admission == SystemControls.Admission.OPEN_APP ||
                admission == SystemControls.Admission.VPN_SETTINGS) {
                SystemControls.openFromWidget(context, action, admission)
            }
            SystemControls.refresh(context)
        }
    }

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val (display, brand) = AppStrings.widgetAppearance(context)
        for (id in ids) manager.updateAppWidget(id, sizedViews(manager.getAppWidgetOptions(id)) {
            side -> initialRemoteViews(display, side, brand)
        })
        SystemControls.refresh(context)
    }

    override fun onEnabled(context: Context) = SystemControls.refresh(context)

    override fun onAppWidgetOptionsChanged(
        context: Context, manager: AppWidgetManager, appWidgetId: Int, newOptions: Bundle,
    ) {
        val (display, brand) = AppStrings.widgetAppearance(context)
        manager.updateAppWidget(appWidgetId, sizedViews(newOptions) {
            side -> initialRemoteViews(display, side, brand)
        })
        SystemControls.refresh(context)
    }

    companion object {
        const val ACTION_START = "io.github.monadboxlab.clashpseudo.widget.START"
        const val ACTION_STOP = "io.github.monadboxlab.clashpseudo.widget.STOP"
        internal const val MIN_SIDE_DP = 144f

        internal fun widgetAction(action: String?): String? = when (action) {
            ACTION_START -> "start"
            ACTION_STOP -> "stop"
            else -> null
        }

        internal fun capsuleAction(value: SystemControls.Projection): String? = when {
            value.action == "stop" -> "stop"
            value.action == "start" && !value.preparing -> "start"
            else -> null
        }

        /**
         * Use actual width/height pairs; legacy extrema represent portrait and
         * landscape pairs.
         */
        @Suppress("DEPRECATION")
        internal fun hostSizes(options: Bundle): List<SizeF> {
            if (Build.VERSION.SDK_INT >= 31) {
                val sizes = if (Build.VERSION.SDK_INT >= 33) {
                    options.getParcelableArrayList(AppWidgetManager.OPTION_APPWIDGET_SIZES, SizeF::class.java)
                } else options.getParcelableArrayList<SizeF>(AppWidgetManager.OPTION_APPWIDGET_SIZES)
                if (!sizes.isNullOrEmpty()) return sizes.distinct()
            }
            return listOf(
                SizeF(options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 160).toFloat(),
                    options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 160).toFloat()),
                SizeF(options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH, 160).toFloat(),
                    options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 160).toFloat()),
            ).distinct()
        }

        internal fun sizedViews(options: Bundle, render: (Float) -> RemoteViews): RemoteViews {
            val sizes = hostSizes(options)
            if (Build.VERSION.SDK_INT >= 31) {
                return RemoteViews(sizes.associateWith { render(min(it.width, it.height)) })
            }
            val portrait = min(sizes[0].width, sizes[0].height)
            val landscape = sizes.getOrElse(1) { sizes[0] }.let { min(it.width, it.height) }
            return if (portrait == landscape) render(portrait)
                else RemoteViews(render(landscape), render(portrait))
        }

        internal fun initialRemoteViews(
            context: Context, sideDp: Float = MIN_SIDE_DP, brand: String = "cinnabar",
        ): RemoteViews = remoteViews(context, SystemControls.project(emptyMap()), sideDp, brand)

        fun update(context: Context, value: SystemControls.Projection) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, VpnWidgetProvider::class.java))
            if (ids.isEmpty()) return
            val (display, brand) = AppStrings.widgetAppearance(context)
            for (id in ids) manager.updateAppWidget(id, sizedViews(manager.getAppWidgetOptions(id)) {
                side -> remoteViews(display, value, side, brand)
            })
        }

        private fun status(value: SystemControls.Projection): Int = when (value.statusResource) {
            R.string.system_control_connected -> when {
                value.failed -> R.string.widget_failed
                value.busy -> R.string.widget_busy
                else -> R.string.widget_running
            }
            R.string.system_control_stopped -> R.string.widget_stopped
            R.string.system_control_starting -> R.string.widget_starting
            R.string.system_control_stopping -> R.string.widget_stopping
            R.string.system_control_failed -> R.string.widget_failed
            R.string.system_control_busy -> R.string.widget_busy
            R.string.system_control_restoring -> R.string.widget_restoring
            else -> R.string.widget_unknown
        }

        private fun mode(value: SystemControls.Projection): Int {
            val current = when (value.modeSource) {
                SystemControls.ModeSource.ACTUAL -> value.mode
                SystemControls.ModeSource.SAVED -> value.savedMode
                SystemControls.ModeSource.CONFIGURATION -> return R.string.widget_mode_config
                SystemControls.ModeSource.UNKNOWN -> return R.string.widget_mode_unknown
            }
            return when (current) {
                "rule" -> R.string.system_control_mode_rule
                "global" -> R.string.system_control_mode_global
                "direct" -> R.string.system_control_mode_direct
                else -> R.string.widget_mode_unknown
            }
        }

        private fun runningConfirmed(value: SystemControls.Projection) = value.phase == "RUNNING" &&
            !value.preparing && !value.busy && !value.failed && !value.pendingRestore

        internal fun controlImage(value: SystemControls.Projection, brand: String, dark: Boolean): Int {
            if (!runningConfirmed(value)) {
                val stopped = value.phase == "STOPPED" && !value.preparing && !value.pendingRestore
                return if (stopped) {
                    if (dark) R.drawable.widget_switch_off_dark else R.drawable.widget_switch_off
                } else if (dark) R.drawable.widget_switch_unknown_dark else R.drawable.widget_switch_unknown
            }
            return when (brand) {
                "jade" -> if (dark) R.drawable.widget_switch_jade_dark else R.drawable.widget_switch_jade
                "cobalt" -> if (dark) R.drawable.widget_switch_cobalt_dark else R.drawable.widget_switch_cobalt
                else -> if (dark) R.drawable.widget_switch_cinnabar_dark else R.drawable.widget_switch_cinnabar
            }
        }

        internal fun remoteViews(
            context: Context, value: SystemControls.Projection,
            sideDp: Float = MIN_SIDE_DP, brand: String = "cinnabar",
        ): RemoteViews {
            require(sideDp.isFinite() && sideDp >= 0)
            val dark = context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK ==
                Configuration.UI_MODE_NIGHT_YES
            val ink = if (dark) 0xffe5e8e6.toInt() else 0xff2e302c.toInt()
            val secondary = if (dark) 0xffadb4b9.toInt() else 0xff706a5f.toInt()
            val side = (sideDp * context.resources.displayMetrics.density).roundToInt()
            val views = RemoteViews(context.packageName, R.layout.vpn_widget)
            val density = context.resources.displayMetrics.density
            val supported = sideDp >= MIN_SIDE_DP
            // The compact fallback needs the square's full width for scaled text.
            val inset = if (!supported) 0 else if (context.resources.configuration.fontScale > 1.3f) 12 else 16
            views.setViewPadding(R.id.widget_open, (inset * density).roundToInt(),
                (4 * density).roundToInt(), (inset * density).roundToInt(), (4 * density).roundToInt())
            views.setInt(R.id.widget_size, "setWidth", side)
            views.setInt(R.id.widget_size, "setHeight", side)
            views.setInt(R.id.widget_open, "setBackgroundResource",
                if (dark) R.drawable.widget_background_dark else R.drawable.widget_background_light)
            views.setOnClickPendingIntent(R.id.widget_open,
                SystemControls.activityPendingIntent(context, SystemControls.overviewIntent(context), 1042))
            views.setBoolean(R.id.widget_control, "setEnabled", false)
            views.setOnClickPendingIntent(R.id.widget_control, null)
            views.setViewVisibility(R.id.widget_content, if (supported) View.VISIBLE else View.GONE)
            views.setViewVisibility(R.id.widget_capacity, if (supported) View.GONE else View.VISIBLE)
            if (!supported) {
                views.setTextViewText(R.id.widget_capacity, context.getString(R.string.widget_capacity))
                views.setTextColor(R.id.widget_capacity, ink)
                views.setContentDescription(R.id.widget_open, context.getString(R.string.widget_capacity))
                return views
            }
            val label = context.getString(status(value))
            val modeDescription = SystemControls.modeText(value, context)
            views.setImageViewResource(R.id.widget_logo, R.drawable.widget_logo)
            views.setTextViewText(R.id.widget_status, label)
            views.setTextViewText(R.id.widget_mode, context.getString(mode(value)))
            views.setTextColor(R.id.widget_status, ink)
            views.setTextColor(R.id.widget_mode, secondary)
            views.setContentDescription(R.id.widget_open,
                context.getString(R.string.widget_open_description, label, modeDescription))
            views.setImageViewResource(R.id.widget_control, controlImage(value, brand, dark))
            val action = capsuleAction(value)
            val enabled = action != null && value.enabled
            views.setContentDescription(R.id.widget_control, when {
                !enabled -> context.getString(R.string.system_control_action_unavailable, label)
                action == "start" -> context.getString(R.string.system_control_action_start)
                else -> context.getString(R.string.system_control_action_stop)
            })
            views.setBoolean(R.id.widget_control, "setEnabled", enabled)
            if (enabled) views.setOnClickPendingIntent(R.id.widget_control,
                PendingIntent.getBroadcast(context, if (action == "start") 1051 else 1052,
                    Intent(context, VpnWidgetProvider::class.java)
                        .setAction(if (action == "start") ACTION_START else ACTION_STOP),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            return views
        }
    }
}

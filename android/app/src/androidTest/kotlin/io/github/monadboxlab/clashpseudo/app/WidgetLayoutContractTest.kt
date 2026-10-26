package io.github.monadboxlab.clashpseudo.app

import android.appwidget.AppWidgetManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.util.SizeF
import android.view.View
import android.view.ViewGroup
import android.widget.ImageButton
import android.widget.RemoteViews
import android.widget.TextView
import androidx.test.platform.app.InstrumentationRegistry
import io.github.monadboxlab.clashpseudo.R
import io.github.monadboxlab.clashpseudo.controls.SystemControls
import kotlin.math.min
import org.junit.Assert.*
import org.junit.Test

/** Measure all recorded host-size pairs; insufficient capacity fails the case. */
class WidgetLayoutContractTest {
    private data class Case(
        val name: String, val projection: SystemControls.Projection,
        val label: Int, val mode: Int, val action: String?, val enabled: Boolean,
        val running: Boolean = false,
    )

    private fun projection(
        phase: String, mode: String? = null, saved: String? = null, known: Boolean = false,
        busy: Boolean = false, failed: Boolean = false, pending: Boolean = false,
        system: Boolean = false, restore: Boolean = false,
    ) = SystemControls.Projection(phase, mode, saved, known, busy, failed, pending, system,
        restore)

    private val cases = listOf(
        Case("stopped-unknown-mode", projection("STOPPED"), R.string.widget_stopped,
            R.string.widget_mode_unknown, "start", true),
        Case("stopped-config", projection("STOPPED", known = true), R.string.widget_stopped,
            R.string.widget_mode_config, "start", true),
        Case("saved-rule", projection("STOPPED", saved = "rule", known = true), R.string.widget_stopped,
            R.string.system_control_mode_rule, "start", true),
        Case("saved-global", projection("STOPPED", saved = "global", known = true), R.string.widget_stopped,
            R.string.system_control_mode_global, "start", true),
        Case("saved-direct", projection("STOPPED", saved = "direct", known = true), R.string.widget_stopped,
            R.string.system_control_mode_direct, "start", true),
        Case("starting", projection("STARTING"), R.string.widget_starting,
            R.string.widget_mode_unknown, "stop", true),
        Case("queued-start", projection("STOPPED", pending = true), R.string.widget_starting,
            R.string.widget_mode_unknown, "stop", true),
        Case("queued-system-start", projection("STOPPED", system = true), R.string.widget_starting,
            R.string.widget_mode_unknown, "stop", true),
        Case("running-rule", projection("RUNNING", mode = "rule"), R.string.widget_running,
            R.string.system_control_mode_rule, "stop", true, running = true),
        Case("running-global", projection("RUNNING", mode = "global"), R.string.widget_running,
            R.string.system_control_mode_global, "stop", true, running = true),
        Case("running-direct", projection("RUNNING", mode = "direct"), R.string.widget_running,
            R.string.system_control_mode_direct, "stop", true, running = true),
        Case("running-busy", projection("RUNNING", mode = "rule", busy = true), R.string.widget_busy,
            R.string.system_control_mode_rule, "stop", true),
        Case("running-failed", projection("RUNNING", mode = "rule", failed = true), R.string.widget_failed,
            R.string.system_control_mode_rule, "stop", true),
        Case("stopping", projection("STOPPING"), R.string.widget_stopping,
            R.string.widget_mode_unknown, null, false),
        Case("unknown", projection("UNKNOWN"), R.string.widget_unknown,
            R.string.widget_mode_unknown, null, false),
        Case("failed-start", projection("STOPPED", failed = true), R.string.widget_failed,
            R.string.widget_mode_unknown, "start", true),
        Case("busy-stopped", projection("STOPPED", busy = true), R.string.widget_busy,
            R.string.widget_mode_unknown, "start", false),
        Case("restore-pending", projection("STOPPED", restore = true), R.string.widget_restoring,
            R.string.widget_mode_unknown, "stop", true),
    )

    private val fields = listOf(R.id.widget_status, R.id.widget_mode,
        R.id.widget_logo, R.id.widget_control)

    private fun anchors(root: ViewGroup) = fields.map { WidgetGeometry.rect(root, it) }

    private fun expectedControl(case: Case, brand: String, dark: Boolean): Int = when {
        case.running && brand == "jade" -> if (dark) R.drawable.widget_switch_jade_dark else R.drawable.widget_switch_jade
        case.running && brand == "cobalt" -> if (dark) R.drawable.widget_switch_cobalt_dark else R.drawable.widget_switch_cobalt
        case.running -> if (dark) R.drawable.widget_switch_cinnabar_dark else R.drawable.widget_switch_cinnabar
        case.name in setOf("stopped-unknown-mode", "stopped-config", "saved-rule", "saved-global", "saved-direct", "failed-start", "busy-stopped") ->
            if (dark) R.drawable.widget_switch_off_dark else R.drawable.widget_switch_off
        else -> if (dark) R.drawable.widget_switch_unknown_dark else R.drawable.widget_switch_unknown
    }

    private fun image(drawable: android.graphics.drawable.Drawable, width: Int = 48, height: Int = 48): IntArray {
        val bounds = android.graphics.Rect(drawable.bounds)
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        try {
            drawable.setBounds(0, 0, width, height)
            drawable.draw(Canvas(bitmap))
            return IntArray(width * height).also { bitmap.getPixels(it, 0, width, 0, 0, width, height) }
        } finally {
            drawable.bounds = bounds
            bitmap.recycle()
        }
    }

    private fun assertDensity(root: ViewGroup, context: android.content.Context) {
        val logo = WidgetGeometry.rect(root, R.id.widget_logo)
        val control = WidgetGeometry.rect(root, R.id.widget_control)
        val status = WidgetGeometry.rect(root, R.id.widget_status_slot)
        val footer = WidgetGeometry.rect(root, R.id.widget_mode_slot)
        val content = WidgetGeometry.rect(root, R.id.widget_content)
        val square = WidgetGeometry.rect(root, R.id.widget_open)
        assertEquals("Logo must not be smaller than the adjacent control", control.height(), logo.height())
        assertEquals(WidgetGeometry.px(context, 48f), logo.width())
        assertEquals("Header visual centers", control.centerY(), logo.centerY())
        assertTrue("An empty center separates controls from state: $control / $status",
            status.top - control.bottom <= WidgetGeometry.px(context, 16f))
        assertTrue("State and mode lost their grouping: $status / $footer",
            footer.top - status.bottom in 0..WidgetGeometry.px(context, 4f))
        assertTrue("Content group must be vertically centered rather than spread to the edges",
            kotlin.math.abs(content.top + content.bottom - square.top - square.bottom) <= 1)
        assertTrue("Content reaches outside the safe inset", content.top >= square.top + WidgetGeometry.px(context, 4f) &&
            content.bottom <= square.bottom - WidgetGeometry.px(context, 4f))
        val statusText = root.findViewById<TextView>(R.id.widget_status)
        val modeText = root.findViewById<TextView>(R.id.widget_mode)
        fun sp(value: Float) = android.util.TypedValue.applyDimension(
            android.util.TypedValue.COMPLEX_UNIT_SP, value, context.resources.displayMetrics).let {
                (it + .5f).toInt().toFloat()
            }
        assertEquals(sp(16f), statusText.textSize, .01f)
        assertEquals(sp(14f), modeText.textSize, .01f)
        val capsule = root.findViewById<ImageButton>(R.id.widget_control)
        assertEquals(control.width(), capsule.drawable.intrinsicWidth)
        assertEquals(control.height(), capsule.drawable.intrinsicHeight)
        val visible = image(capsule.drawable, 56, 48).withIndex().filter { it.value ushr 24 > 0 }
        val visualWidth = visible.maxOf { it.index % 56 } - visible.minOf { it.index % 56 } + 1
        val visualHeight = visible.maxOf { it.index / 56 } - visible.minOf { it.index / 56 } + 1
        assertTrue("A large hit box must not conceal an undersized capsule: ${visualWidth}x$visualHeight",
            visualWidth >= 52 && visualHeight >= 32)
        val pixels = image(root.findViewById<android.widget.ImageView>(R.id.widget_logo).drawable)
        assertEquals("Logo corners must be transparent on every API", 0, pixels.first() ushr 24)
        assertEquals("Logo center must remain opaque", 255, pixels[24 * 48 + 24] ushr 24)
    }

    @Test fun everyRecordedHostPairShowsACompleteSquareOrAnExplicitCapacityError() {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        val failures = mutableListOf<String>()
        var complete = 0
        var capacity = 0
        val boundaries = listOf(SizeF(160f, 160f), SizeF(160f, 260f),
            SizeF(260f, 160f), SizeF(159f, 200f),
            SizeF(144f, 144f), SizeF(144f, 260f), SizeF(260f, 144f), SizeF(143f, 200f))
        for (language in listOf("en", "zh")) for (scale in listOf(1f, 1.3f, 2f)) {
            for (dark in listOf(false, true)) for (brand in listOf("cinnabar", "jade", "cobalt")) {
                for ((index, bounds) in (WidgetGeometry.recordedHosts + boundaries).withIndex()) {
                    val label = "host=$index/$bounds/$language/font=$scale/dark=$dark/brand=$brand"
                    try {
                        val local = WidgetGeometry.local(base, language, scale, dark)
                        val side = min(bounds.width, bounds.height)
                        WidgetGeometry.onMain {
                            val root = WidgetGeometry.apply(
                                VpnWidgetProvider.initialRemoteViews(local, side, brand), local, bounds)
                            WidgetGeometry.assertSquare(root, local, bounds)
                            val supported = side >= 144f
                            val baseline = if (supported) anchors(root) else emptyList()
                            for (case in cases) {
                                VpnWidgetProvider.remoteViews(local, case.projection, side, brand).reapply(local, root)
                                WidgetGeometry.measure(root, local, bounds)
                                WidgetGeometry.assertSquare(root, local, bounds)
                                assertTrue(root.findViewById<View>(R.id.widget_open).hasOnClickListeners())
                                val control = root.findViewById<ImageButton>(R.id.widget_control)
                                if (!supported) {
                                    assertEquals(View.GONE, root.findViewById<View>(R.id.widget_content).visibility)
                                    assertEquals(View.VISIBLE, root.findViewById<View>(R.id.widget_capacity).visibility)
                                    assertEquals(local.getString(R.string.widget_capacity),
                                        root.findViewById<TextView>(R.id.widget_capacity).text.toString())
                                    WidgetGeometry.assertTextFits(root, R.id.widget_capacity)
                                    val capacityText = root.findViewById<TextView>(R.id.widget_capacity)
                                    val expectedSize = android.util.TypedValue.applyDimension(
                                        android.util.TypedValue.COMPLEX_UNIT_SP, 12f, local.resources.displayMetrics)
                                    assertEquals((expectedSize + .5f).toInt().toFloat(), capacityText.textSize, .01f)
                                    assertEquals(local.getString(R.string.widget_capacity),
                                        root.findViewById<View>(R.id.widget_open).contentDescription.toString())
                                    assertFalse(control.isEnabled)
                                    assertFalse(control.hasOnClickListeners())
                                } else {
                                    assertEquals(View.GONE, root.findViewById<View>(R.id.widget_capacity).visibility)
                                    assertEquals(View.VISIBLE, root.findViewById<View>(R.id.widget_content).visibility)
                                    assertEquals("$label/${case.name} changed anchors", baseline, anchors(root))
                                    for (id in fields.take(2)) WidgetGeometry.assertTextFits(root, id)
                                    assertDensity(root, local)
                                    assertEquals(local.getString(case.label), root.findViewById<TextView>(R.id.widget_status).text.toString())
                                    assertEquals(local.getString(case.mode), root.findViewById<TextView>(R.id.widget_mode).text.toString())
                                    val actionDescription = if (!case.enabled) local.getString(
                                        R.string.system_control_action_unavailable, local.getString(case.label))
                                        else local.getString(if (case.action == "start") R.string.system_control_action_start
                                            else R.string.system_control_action_stop)
                                    assertEquals(actionDescription, control.contentDescription.toString())
                                    assertEquals(case.enabled, control.isEnabled)
                                    assertEquals(case.enabled, control.hasOnClickListeners())
                                    assertArrayEquals("$label/${case.name} used an incorrect/tinted switch",
                                        image(checkNotNull(local.getDrawable(expectedControl(case, brand, dark))), 56, 48),
                                        image(control.drawable, 56, 48))
                                    val description = root.findViewById<View>(R.id.widget_open).contentDescription.toString()
                                    assertTrue(description.contains(SystemControls.modeText(case.projection, local)))
                                    assertEquals(local.getString(R.string.widget_open_description,
                                        local.getString(case.label), SystemControls.modeText(case.projection, local)), description)
                                    assertEquals(2, WidgetGeometry.descendants(root).filterIsInstance<TextView>()
                                        .count { it.visibility == View.VISIBLE })
                                    val hit = WidgetGeometry.rect(root, R.id.widget_control)
                                    assertEquals(WidgetGeometry.px(local, 56f), hit.width())
                                    assertEquals(WidgetGeometry.px(local, 48f), hit.height())
                                    val status = WidgetGeometry.rect(root, R.id.widget_status_slot)
                                    assertFalse("Control overlaps status: $hit / $status",
                                        android.graphics.Rect.intersects(hit, status))
                                    assertTrue("Control needs a visible gap above status: $hit / $status",
                                        status.top - hit.bottom >= WidgetGeometry.px(local, 4f))
                                }
                            }
                        }
                        if (index < WidgetGeometry.recordedHosts.size) {
                            if (side >= 144) complete++ else capacity++
                        }
                    } catch (error: Throwable) {
                        failures += "$label: ${error.javaClass.simpleName}: ${error.message}"
                    }
                }
            }
        }
        Log.i("PseudoWidgetContract", "api=${Build.VERSION.SDK_INT} recordedComplete=$complete " +
            "recordedCapacity=$capacity recordedExpected=828 failures=${failures.size} noSkippedPairs=true")
        failures.forEach { Log.e("PseudoWidgetContract", it) }
        assertTrue("Widget matrix failed:\n${failures.joinToString("\n")}", failures.isEmpty())
        assertEquals(828, complete + capacity)
    }

    @Test fun sizeSelectionUsesOnlyActualOrientationPairs() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val options = Bundle().apply {
            putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 180)
            putInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH, 300)
            putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 200)
            putInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 300)
            if (Build.VERSION.SDK_INT >= 31) putParcelableArrayList(AppWidgetManager.OPTION_APPWIDGET_SIZES,
                arrayListOf(SizeF(180f, 300f), SizeF(300f, 200f)))
        }
        val sides = mutableListOf<Float>()
        VpnWidgetProvider.sizedViews(options) { side ->
            sides += side
            RemoteViews(context.packageName, R.layout.vpn_widget)
        }
        assertEquals(listOf(180f, 200f), sides.sorted())
        assertEquals(listOf(SizeF(180f, 300f), SizeF(300f, 200f)), VpnWidgetProvider.hostSizes(options))
    }
}

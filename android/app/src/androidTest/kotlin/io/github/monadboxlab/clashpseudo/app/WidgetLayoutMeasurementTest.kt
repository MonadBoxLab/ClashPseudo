package io.github.monadboxlab.clashpseudo.app

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.os.Build
import android.util.Log
import android.util.SizeF
import android.widget.TextView
import androidx.test.platform.app.InstrumentationRegistry
import io.github.monadboxlab.clashpseudo.R
import kotlin.math.min
import org.junit.Assert.*
import org.junit.Test

/** Read-only SDK measurements across the complete capacity and font matrix. */
class WidgetLayoutMeasurementTest {
    @Suppress("DEPRECATION")
    @Test fun reportInstalledWidgetHostOptionsWithoutChangingAnyInstance() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val manager = AppWidgetManager.getInstance(context)
        val component = ComponentName(context, VpnWidgetProvider::class.java)
        val ids = manager.getAppWidgetIds(component)
        Log.i("PseudoWidgetHost", "api=${Build.VERSION.SDK_INT} component=$component ids=${ids.toList()} " +
            "fontScale=${context.resources.configuration.fontScale} density=${context.resources.displayMetrics.density}")
        assertTrue("No installed instance: real Launcher allocation has not been measured", ids.isNotEmpty())
        for (id in ids) {
            val options = manager.getAppWidgetOptions(id)
            fun value(name: String) = if (options.containsKey(name)) options.getInt(name).toString() else "absent"
            val paired = if (Build.VERSION.SDK_INT >= 31) {
                options.getParcelableArrayList<SizeF>(AppWidgetManager.OPTION_APPWIDGET_SIZES)
                    ?.joinToString(prefix = "[", postfix = "]") { "${it.width}x${it.height}" } ?: "absent"
            } else "unsupported-before-api31"
            Log.i("PseudoWidgetHost", "id=$id pairedSizesDp=$paired " +
                "minWidthDp=${value(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH)} " +
                "maxWidthDp=${value(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH)} " +
                "minHeightDp=${value(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT)} " +
                "maxHeightDp=${value(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT)} diagnosticOnly=true")
        }
    }

    @Test fun saveOffscreenCompositionPreviewsWithoutUpdatingAWidget() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val base = instrumentation.targetContext
        val nonce = androidx.test.platform.app.InstrumentationRegistry.getArguments().getString("previewNonce")
            ?: java.util.UUID.randomUUID().toString()
        require(nonce.matches(Regex("[a-z0-9-]{8,48}")))
        val directory = java.io.File(base.getExternalFilesDir(null), "widget-previews-$nonce")
        check(!directory.exists() && directory.mkdir())
        for (language in listOf("en", "zh")) {
            val cell = WidgetGeometry.px(base, 210f)
            val bitmap = android.graphics.Bitmap.createBitmap(cell * 3, cell * 4,
                android.graphics.Bitmap.Config.ARGB_8888)
            try {
                val canvas = android.graphics.Canvas(bitmap)
                canvas.drawColor(0xffdedede.toInt())
                val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
                    color = android.graphics.Color.BLACK
                    textSize = WidgetGeometry.px(base, 10f).toFloat()
                }
                for ((column, scale) in listOf(1f, 1.3f, 2f).withIndex()) {
                    for ((row, side) in listOf(144f, 145.5238f, 160f, 187f).withIndex()) {
                        val local = WidgetGeometry.local(base, language, scale, false)
                        WidgetGeometry.onMain {
                            val value = io.github.monadboxlab.clashpseudo.controls.SystemControls.Projection(
                                "STOPPED", null, "global", true, false, false, false, false)
                            val root = WidgetGeometry.apply(VpnWidgetProvider.remoteViews(local, value, side),
                                local, SizeF(side, side))
                            for (id in listOf(R.id.widget_status, R.id.widget_mode))
                                WidgetGeometry.assertTextFits(root, id)
                            canvas.save()
                            canvas.translate((column * cell).toFloat(), (row * cell).toFloat())
                            root.draw(canvas)
                            canvas.restore()
                        }
                        canvas.drawText("$language / ${side}dp / ${scale}x / offscreen SDK",
                            (column * cell + 3).toFloat(), (row * cell + cell - 6).toFloat(), paint)
                    }
                }
                java.io.File(directory, "$language.png").outputStream().use {
                    assertTrue(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it))
                }
            } finally { bitmap.recycle() }
        }
        Log.i("PseudoWidgetPreview", "Offscreen only, no installed widget update: $directory")
    }

    @Test fun reportActualSquareAndTextGeometryForEveryRecordedPair() {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        var measured = 0
        for (language in listOf("en", "zh")) for (scale in listOf(1f, 1.3f, 2f)) {
            for ((index, bounds) in WidgetGeometry.recordedHosts.withIndex()) {
                val local = WidgetGeometry.local(base, language, scale, false)
                val side = min(bounds.width, bounds.height)
                WidgetGeometry.onMain {
                    val root = WidgetGeometry.apply(VpnWidgetProvider.initialRemoteViews(local, side), local, bounds)
                    WidgetGeometry.assertSquare(root, local, bounds)
                    val square = WidgetGeometry.rect(root, R.id.widget_open)
                    val geometry = listOf(R.id.widget_status, R.id.widget_mode,
                        R.id.widget_capacity).joinToString { id ->
                        val text = root.findViewById<TextView>(id)
                        "${local.resources.getResourceEntryName(id)}:visible=${text.visibility}," +
                            "actual=${text.width}x${text.height},layoutHeight=${text.layout?.height},fontPx=${text.textSize}"
                    }
                    Log.i("PseudoWidgetMeasure", "api=${Build.VERSION.SDK_INT} hostIndex=$index hostDp=$bounds " +
                        "language=$language fontScale=$scale squarePx=$square " +
                        "capacityError=${side < 144f} fields=[$geometry]")
                    measured++
                }
            }
        }
        assertEquals("Every recorded pair must be measured in both languages and all three font scales", 138, measured)
    }
}

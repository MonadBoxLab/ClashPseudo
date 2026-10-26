package io.github.monadboxlab.clashpseudo.app

import android.content.Context
import android.content.res.Configuration
import android.graphics.Rect
import android.util.SizeF
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.RemoteViews
import android.widget.TextView
import androidx.test.platform.app.InstrumentationRegistry
import io.github.monadboxlab.clashpseudo.R
import java.util.Locale
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.min
import kotlin.math.roundToInt
import org.junit.Assert.*

/** Offscreen SDK view measurement helpers. */
internal object WidgetGeometry {
    val recordedHosts = listOf(
        SizeF(145.5238f, 433.5238f), SizeF(285.7143f, 210.66667f),
        SizeF(179.42857f, 200.7619f), SizeF(179.42857f, 202.66667f),
        SizeF(155.80952f, 223.61905f), SizeF(155.80952f, 223.61905f),
        SizeF(336f, 131.04762f), SizeF(187.42857f, 185.5238f),
        SizeF(187.42857f, 185.5238f), SizeF(336f, 131.04762f), SizeF(140f, 136f),
        SizeF(224.38095f, 433.5238f), SizeF(434.66666f, 210.66667f),
        // API24 original allocation: the SDK's legacy portrait/landscape pairs.
        SizeF(160f, 281f), SizeF(214f, 227f),
        // API37 original allocation: preserve the SDK's complete size-pair list.
        SizeF(179.42857f, 209.14285f), SizeF(179.42857f, 167.2381f),
        SizeF(179.42857f, 169.14285f), SizeF(179.42857f, 201.14285f),
        SizeF(339.0476f, 107.42857f), SizeF(419.0476f, 107.42857f),
        SizeF(419.0476f, 107.42857f), SizeF(339.0476f, 107.42857f),
    )

    fun local(base: Context, language: String, scale: Float, dark: Boolean): Context =
        base.createConfigurationContext(Configuration(base.resources.configuration).apply {
            setLocale(Locale.forLanguageTag(language))
            fontScale = scale
            uiMode = (uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or
                if (dark) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO
        })

    fun onMain(block: () -> Unit) {
        val failure = AtomicReference<Throwable?>()
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            try { block() } catch (error: Throwable) { failure.set(error) }
        }
        failure.get()?.let { throw it }
    }

    fun px(context: Context, dp: Float): Int = (dp * context.resources.displayMetrics.density).roundToInt()

    fun measure(root: View, context: Context, bounds: SizeF) {
        root.measure(View.MeasureSpec.makeMeasureSpec(px(context, bounds.width), View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(px(context, bounds.height), View.MeasureSpec.EXACTLY))
        root.layout(0, 0, root.measuredWidth, root.measuredHeight)
    }

    fun apply(views: RemoteViews, context: Context, bounds: SizeF): ViewGroup =
        (views.apply(context, FrameLayout(context)) as ViewGroup).also { measure(it, context, bounds) }

    fun rect(root: ViewGroup, child: View): Rect = Rect(0, 0, child.width, child.height).also {
        root.offsetDescendantRectToMyCoords(child, it)
    }

    fun rect(root: ViewGroup, id: Int): Rect = rect(root, root.findViewById(id))

    fun descendants(view: View): List<View> = listOf(view) + if (view is ViewGroup)
        (0 until view.childCount).flatMap { descendants(view.getChildAt(it)) } else emptyList()

    fun assertSquare(root: ViewGroup, context: Context, bounds: SizeF) {
        val square = rect(root, R.id.widget_open)
        val side = px(context, min(bounds.width, bounds.height))
        assertEquals("Square width", side, square.width())
        assertEquals("Square height", side, square.height())
        assertTrue("Square is not horizontally centered: $square / ${root.width}",
            kotlin.math.abs(square.left * 2 + side - root.width) <= 1)
        assertTrue("Square is not vertically centered: $square / ${root.height}",
            kotlin.math.abs(square.top * 2 + side - root.height) <= 1)
        assertTrue("Square exceeds its host: $square", square.left >= 0 && square.top >= 0 &&
            square.right <= root.width && square.bottom <= root.height)
    }

    fun assertTextFits(root: ViewGroup, id: Int) {
        val text = root.findViewById<TextView>(id)
        val layout = checkNotNull(text.layout)
        val name = text.resources.getResourceEntryName(id)
        assertTrue("$name has empty dimensions", text.width > 0 && text.height > 0)
        assertTrue("$name clipped vertically: ${layout.height} / ${text.height}",
            layout.height <= text.height - text.compoundPaddingTop - text.compoundPaddingBottom)
        for (line in 0 until layout.lineCount) {
            assertEquals("$name was ellipsized", 0, layout.getEllipsisCount(line))
            assertTrue("$name exceeded line width: ${layout.getLineMax(line)} / ${text.width}",
                layout.getLineMax(line) <= text.width - text.compoundPaddingLeft - text.compoundPaddingRight)
        }
        val box = rect(root, text)
        val square = rect(root, R.id.widget_open)
        assertTrue("$name exceeds the square: $box / $square", square.contains(box))
    }
}

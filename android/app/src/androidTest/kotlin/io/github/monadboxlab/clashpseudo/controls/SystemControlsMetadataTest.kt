package io.github.monadboxlab.clashpseudo.controls

import io.github.monadboxlab.clashpseudo.app.VpnTileService
import io.github.monadboxlab.clashpseudo.app.VpnWidgetProvider

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProviderInfo
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Process
import android.service.quicksettings.TileService
import android.util.TypedValue
import androidx.test.platform.app.InstrumentationRegistry
import io.github.monadboxlab.clashpseudo.R
import kotlin.math.roundToInt
import org.junit.Assert.*
import org.junit.Test
import org.xmlpull.v1.XmlPullParser

/** Exercises SDK component discovery and lazy provider metadata parsing. */
class SystemControlsMetadataTest {
    @Test fun installedWidgetProviderResolvesItsCurrentSdkMetadataAndResources() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val component = ComponentName(context, VpnWidgetProvider::class.java)
        val user = Process.myUserHandle()
        val providers = AppWidgetManager.getInstance(context)
            .getInstalledProvidersForProfile(user).filter { it.provider == component }
        assertEquals("Widget provider missing from real SDK discovery on API ${Build.VERSION.SDK_INT}",
            1, providers.size)
        val info = providers.single()
        assertEquals(user, info.profile)
        assertEquals(R.layout.vpn_widget, info.initialLayout)
        assertEquals("layout", context.resources.getResourceTypeName(info.initialLayout))
        context.resources.getXml(info.initialLayout).use { parser ->
            while (parser.eventType != XmlPullParser.START_TAG &&
                parser.eventType != XmlPullParser.END_DOCUMENT) parser.next()
            assertEquals(XmlPullParser.START_TAG, parser.eventType)
            assertEquals("FrameLayout", parser.name)
        }
        val metrics = context.resources.displayMetrics
        val side = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, 144f, metrics).roundToInt()
        assertEquals(side, info.minWidth)
        assertEquals(side, info.minHeight)
        assertEquals(AppWidgetProviderInfo.RESIZE_NONE, info.resizeMode)
        assertEquals(AppWidgetProviderInfo.WIDGET_CATEGORY_HOME_SCREEN, info.widgetCategory)
        assertEquals(0, info.updatePeriodMillis)
        if (Build.VERSION.SDK_INT >= 31) {
            assertEquals(0, info.targetCellWidth)
            assertEquals(0, info.targetCellHeight)
            assertEquals(R.layout.vpn_widget, info.previewLayout)
            assertEquals(R.string.system_control_widget_description, info.descriptionRes)
            assertEquals(context.getString(R.string.system_control_widget_description),
                info.loadDescription(context)?.toString())
            assertEquals(0, info.previewImage)
        } else {
            assertEquals(R.mipmap.ic_launcher, info.previewImage)
            assertEquals("mipmap", context.resources.getResourceTypeName(info.previewImage))
        }
    }

    @Suppress("DEPRECATION") // The public int-flags overloads also support API 24.
    @Test fun tileServiceResolvesItsSystemPermissionActionAndMetadata() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val component = ComponentName(context, VpnTileService::class.java)
        val manager = context.packageManager
        val service = manager.getServiceInfo(component, PackageManager.GET_META_DATA)
        assertEquals(component.packageName, service.packageName)
        assertEquals(component.className, service.name)
        assertTrue(service.enabled)
        assertTrue(service.exported)
        assertEquals("android.permission.BIND_QUICK_SETTINGS_TILE", service.permission)
        assertNotNull(service.metaData)
        assertTrue(service.metaData.getBoolean(TileService.META_DATA_ACTIVE_TILE))
        if (Build.VERSION.SDK_INT >= 30) {
            assertTrue(service.metaData.getBoolean(TileService.META_DATA_TOGGLEABLE_TILE))
        }
        assertEquals(R.drawable.ic_vpn_notification, service.icon)
        assertEquals("drawable", context.resources.getResourceTypeName(service.icon))
        assertEquals(R.string.system_control_title, service.labelRes)
        // Use a package-scoped implicit query to inspect the action filter.
        val matches = manager.queryIntentServices(
            Intent(TileService.ACTION_QS_TILE).setPackage(context.packageName),
            PackageManager.GET_META_DATA,
        ).map { ComponentName(it.serviceInfo.packageName, it.serviceInfo.name) }
        assertTrue("Tile service missing its QS_TILE intent filter", component in matches)
    }
}

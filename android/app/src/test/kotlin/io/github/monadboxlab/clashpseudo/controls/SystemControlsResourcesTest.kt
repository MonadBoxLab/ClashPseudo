package io.github.monadboxlab.clashpseudo.controls

import org.junit.Assert.*
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import java.util.Locale
import javax.xml.parsers.DocumentBuilderFactory

/** Host-only checks of the actual manifest and RemoteViews resource contracts. */
class SystemControlsResourcesTest {
    private val android = "http://schemas.android.com/apk/res/android"
    private fun document(path: String) = DocumentBuilderFactory.newInstance().apply {
        isNamespaceAware = true
        setFeature("http://apache.org/xml/features/disallow-doctype-decl", true)
    }.newDocumentBuilder().parse(File("src/main", path))
    private fun elements(path: String, tag: String): List<Element> {
        val nodes = document(path).getElementsByTagName(tag)
        return (0 until nodes.length).map { nodes.item(it) as Element }
    }
    private fun Element.attr(name: String) = getAttributeNS(android, name)
    private fun strings(path: String): Map<String, String> = elements(path, "string")
        .associate { it.getAttribute("name") to it.textContent }
    private fun style(name: String): Map<String, String> {
        val node = elements("res/values/system_controls.xml", "style").single { it.getAttribute("name") == name }
        val parent = node.getAttribute("parent").takeIf { it.isNotEmpty() }?.let { style(it) }.orEmpty()
        val items = node.getElementsByTagName("item")
        return parent + (0 until items.length).associate { index ->
            val item = items.item(index) as Element
            item.getAttribute("name") to item.textContent
        }
    }

    @Test fun publicActivityAndPrivateAliasesHaveSeparateTrustBoundaries() {
        val activities = elements("AndroidManifest.xml", "activity")
        assertEquals("true", activities.single { it.attr("name") == ".MainActivity" }.attr("exported"))
        val aliases = elements("AndroidManifest.xml", "activity-alias")
        for (name in listOf("\${applicationId}.StartVpnShortcut", "\${applicationId}.StopVpnShortcut")) {
            val alias = aliases.single { it.attr("name") == name }
            assertEquals("false", alias.attr("exported"))
            assertEquals(".MainActivity", alias.attr("targetActivity"))
        }
        val permissions = elements("AndroidManifest.xml", "uses-permission").map { it.attr("name") }
        assertTrue(permissions.contains("android.permission.ACCESS_NETWORK_STATE"))
        assertFalse(permissions.contains("android.permission.RECEIVE_BOOT_COMPLETED"))
    }

    @Test fun lintExceptionsStayOnTheApprovedVpnDeclarations() {
        val tools = "http://schemas.android.com/tools"
        val nodes = document("AndroidManifest.xml").getElementsByTagName("*")
        val exceptions = (0 until nodes.length).map { nodes.item(it) as Element }
            .filter { it.getAttributeNS(tools, "ignore").isNotEmpty() }
        assertEquals(2, exceptions.size)
        assertEquals(mapOf(
            "uses-permission:android.permission.QUERY_ALL_PACKAGES" to "QueryAllPackagesPermission",
            "service:.vpn.PseudoVpnService" to "ForegroundServicePermission",
        ), exceptions.associate { "${it.tagName}:${it.attr("name")}" to it.getAttributeNS(tools, "ignore") })
        val vpn = elements("AndroidManifest.xml", "service").single { it.attr("name") == ".vpn.PseudoVpnService" }
        assertEquals("systemExempted", vpn.attr("foregroundServiceType"))
        assertEquals("android.permission.BIND_VPN_SERVICE", vpn.attr("permission"))
        val permissions = elements("AndroidManifest.xml", "uses-permission").map { it.attr("name") }
        assertTrue(permissions.contains("android.permission.FOREGROUND_SERVICE"))
        assertTrue(permissions.contains("android.permission.FOREGROUND_SERVICE_SYSTEM_EXEMPTED"))
        assertFalse(permissions.contains("android.permission.SCHEDULE_EXACT_ALARM"))
        assertFalse(permissions.contains("android.permission.USE_EXACT_ALARM"))
    }

    @Test fun backupAgentUsesFullBackupWithoutReplacingTheExistingRules() {
        val app = elements("AndroidManifest.xml", "application").single()
        assertEquals(".app.PseudoBackupAgent", app.attr("backupAgent"))
        assertEquals("true", app.attr("fullBackupOnly"))
        assertEquals("@xml/backup_rules", app.attr("fullBackupContent"))
        assertEquals("@xml/data_extraction_rules", app.attr("dataExtractionRules"))
    }

    @Test fun tileIsBoundOnlyThroughTheSystemPermission() {
        val tile = elements("AndroidManifest.xml", "service").single { it.attr("name") == ".app.VpnTileService" }
        assertEquals("true", tile.attr("exported"))
        assertEquals("android.permission.BIND_QUICK_SETTINGS_TILE", tile.attr("permission"))
        val metadata = tile.getElementsByTagName("meta-data")
        val values = (0 until metadata.length).map { metadata.item(it) as Element }
            .associate { it.attr("name") to it.attr("value") }
        assertEquals("true", values["android.service.quicksettings.ACTIVE_TILE"])
        assertEquals("true", values["android.service.quicksettings.TOGGLEABLE_TILE"])
    }

    @Test fun widgetIsPrivateNonPollingAndDeclaresOneNonResizable144DpSquare() {
        val receiver = elements("AndroidManifest.xml", "receiver")
            .single { it.attr("name") == ".app.VpnWidgetProvider" }
        assertEquals("false", receiver.attr("exported"))
        for (path in listOf("res/xml/vpn_widget_info.xml", "res/xml-v31/vpn_widget_info.xml")) {
            val info = document(path).documentElement
            assertEquals("144dp", info.attr("minWidth"))
            assertEquals("144dp", info.attr("minHeight"))
            assertEquals("none", info.attr("resizeMode"))
            assertEquals("0", info.attr("updatePeriodMillis"))
            assertEquals("home_screen", info.attr("widgetCategory"))
            assertEquals("@layout/vpn_widget", info.attr("initialLayout"))
            assertTrue(info.attr("targetCellWidth").isEmpty())
            assertTrue(info.attr("targetCellHeight").isEmpty())
        }
        assertFalse(File("src/main/res/layout/vpn_widget_wide.xml").exists())
    }

    @Test fun squareDimensionAnchorAndAllChildrenUseStandardRemoteViewsClasses() {
        val nodes = elements("res/layout/vpn_widget.xml", "*")
        assertEquals("FrameLayout", nodes.first().tagName)
        assertEquals(setOf("FrameLayout", "RelativeLayout", "LinearLayout", "TextView", "ImageView", "ImageButton"),
            nodes.map { it.tagName }.toSet())
        assertTrue(nodes.none { it.attr("layout_weight").isNotEmpty() })
        val size = nodes.single { it.attr("id") == "@+id/widget_size" }
        // A fixed layout_width would override TextView.setWidth during EXACTLY measurement.
        assertEquals("wrap_content", size.attr("layout_width"))
        assertEquals("wrap_content", size.attr("layout_height"))
        assertEquals("144dp", size.attr("width"))
        assertEquals("144dp", size.attr("height"))
        assertEquals("invisible", size.attr("visibility"))
        assertEquals("no", size.attr("importantForAccessibility"))
        assertEquals("false", size.attr("focusable"))
        assertEquals("false", size.attr("clickable"))
        val square = nodes.single { it.attr("id") == "@+id/widget_square" }
        assertEquals("center", square.attr("layout_gravity"))
        val content = nodes.single { it.attr("id") == "@+id/widget_open" }
        for (edge in listOf("Start", "End", "Top", "Bottom")) {
            assertEquals("@id/widget_size", content.attr("layout_align$edge"))
        }
        val control = nodes.single { it.attr("id") == "@+id/widget_control" }
        assertEquals("56dp", control.attr("layout_width"))
        assertEquals("48dp", control.attr("layout_height"))
        val capsule = style("WidgetControlCapsule")
        assertEquals("@null", capsule["android:tint"])
        assertEquals("@drawable/widget_control_hit", capsule["android:background"])
        assertEquals("false", capsule["android:enabled"])
    }

    @Test fun textSlotsUseReadableNativeTextAndDoNotTruncateOrClaimAState() {
        val nodes = elements("res/layout/vpn_widget.xml", "TextView")
        for ((id, size) in listOf("status" to "16sp", "mode" to "14sp")) {
            val view = nodes.single { it.attr("id") == "@+id/widget_$id" }
            val values = style(view.getAttribute("style").removePrefix("@style/"))
            assertEquals(size, values["android:textSize"])
            assertEquals("match_parent", view.attr("layout_height"))
            for (key in listOf("ellipsize", "maxLines", "maxHeight", "singleLine")) {
                assertTrue(view.attr(key).isEmpty())
                assertFalse(values.containsKey("android:$key"))
            }
        }
        val measured = nodes.filter { it.attr("text") in
            setOf("@string/widget_measure_line") }
        assertEquals(2, measured.size)
        for (view in measured) {
            assertEquals("invisible", view.attr("visibility"))
            assertEquals("no", view.attr("importantForAccessibility"))
            assertEquals("false", view.attr("focusable"))
            assertEquals("false", view.attr("clickable"))
        }
        val initial = nodes.single { it.attr("id") == "@+id/widget_status" }
        assertEquals("@string/widget_unknown", initial.attr("text"))
        val capacity = nodes.single { it.attr("id") == "@+id/widget_capacity" }
        assertEquals("gone", capacity.attr("visibility"))
        assertEquals("@string/widget_capacity", capacity.attr("text"))
    }

    @Test fun contentIsGroupedAndLogoDoesNotDependOnAnAdaptiveLauncherMask() {
        val nodes = elements("res/layout/vpn_widget.xml", "*")
        val content = nodes.single { it.attr("id") == "@+id/widget_content" }
        assertEquals("LinearLayout", content.tagName)
        assertEquals("wrap_content", content.attr("layout_height"))
        assertEquals("true", content.attr("layout_centerVertical"))
        val logo = nodes.single { it.attr("id") == "@+id/widget_logo" }
        assertEquals("48dp", logo.attr("layout_width"))
        assertEquals("48dp", logo.attr("layout_height"))
        assertEquals("@drawable/widget_logo", logo.attr("src"))
        for (density in listOf("mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi")) {
            assertTrue(File("src/main/res/drawable-$density/widget_logo.png").isFile)
        }
    }

    @Test fun fallbackLineSpacingIsDeclaredOnlyInTheApi28StyleOverlay() {
        assertFalse(style("WidgetControlText").containsKey("android:fallbackLineSpacing"))
        val overlay = elements("res/values-v28/system_controls.xml", "style").single()
        assertEquals("WidgetControlText", overlay.getAttribute("name"))
        assertEquals("WidgetControlTextBase", overlay.getAttribute("parent"))
        val items = overlay.getElementsByTagName("item")
        assertEquals(1, items.length)
        assertEquals("android:fallbackLineSpacing", (items.item(0) as Element).getAttribute("name"))
        assertEquals("true", items.item(0).textContent)
    }

    @Test fun everyNativeControlLabelHasBothAppLanguagesAndCompactWidgetReadings() {
        fun labels(path: String) = strings(path).filterKeys {
            it.startsWith("system_control_") || it.startsWith("widget_")
        }
        val en = labels("res/values/strings.xml")
        val zh = labels("res/values-zh/strings.xml")
        assertTrue(en.isNotEmpty())
        assertEquals(en.keys, zh.keys)
        assertTrue(en.values.all { it.isNotBlank() })
        assertTrue(zh.values.all { it.isNotBlank() })
        assertEquals("Running", en["widget_running"])
        assertEquals("运行中", zh["widget_running"])
        assertEquals("Restore", en["widget_restoring"])
        assertEquals("恢复中", zh["widget_restoring"])
        assertEquals("Config", en["widget_mode_config"])
        assertEquals("配置", zh["widget_mode_config"])
        assertTrue(en.getValue("widget_capacity").contains("Open app"))
        assertTrue(zh.getValue("widget_capacity").contains("打开应用"))
        assertNotEquals(en["system_control_action_start"], en["system_control_action_stop"])
        assertNotEquals(zh["system_control_action_start"], zh["system_control_action_stop"])
    }

    @Test fun textAndFixedSwitchVectorsMeetTheirActualSurfaceContrast() {
        fun luminance(hex: String): Double {
            val channels = (0..2).map { hex.substring(it * 2, it * 2 + 2).toInt(16) / 255.0 }
                .map { if (it <= 0.04045) it / 12.92 else Math.pow((it + 0.055) / 1.055, 2.4) }
            return channels.zip(listOf(0.2126, 0.7152, 0.0722)).sumOf { it.first * it.second }
        }
        fun contrast(a: String, b: String): Double {
            val values = listOf(luminance(a.removePrefix("#")), luminance(b.removePrefix("#"))).sorted()
            return (values[1] + 0.05) / (values[0] + 0.05)
        }
        for ((directory, suffix) in listOf("values" to "", "values-night" to "_dark")) {
            val colors = elements("res/$directory/system_controls.xml", "color")
                .associate { it.getAttribute("name") to it.textContent }
            val background = colors.getValue("system_control_surface")
            for (name in listOf("system_control_text", "system_control_secondary")) {
                assertTrue("$name on $background", contrast(colors.getValue(name), background) >= 4.5)
            }
            for (brand in listOf("cinnabar", "jade", "cobalt")) {
                val paths = elements("res/drawable/widget_switch_$brand$suffix.xml", "path")
                val track = paths[0].attr("fillColor")
                val thumb = paths[1].attr("fillColor")
                assertTrue("$brand$suffix track", contrast(track, background) >= 3)
                assertTrue("$brand$suffix thumb", contrast(thumb, track) >= 3)
            }
            for (state in listOf("off", "unknown")) {
                val path = elements("res/drawable/widget_switch_$state$suffix.xml", "path").first()
                assertTrue(contrast(path.attr("strokeColor"), background) >= 3)
                assertTrue(contrast(path.attr("strokeColor"), path.attr("fillColor")) >= 3)
            }
        }
    }

    @Test fun widgetAccessibilityHasStatusAndModeButNoTimestampOrEmptyTimeSlot() {
        val nodes = elements("res/layout/vpn_widget.xml", "*")
        assertTrue(nodes.none { it.attr("id").contains("snapshot") })
        assertTrue(elements("res/values/system_controls.xml", "style")
            .none { it.getAttribute("name") == "WidgetControlSnapshot" })
        for (language in listOf("en", "zh")) {
            val path = if (language == "zh") "res/values-zh/strings.xml" else "res/values/strings.xml"
            val values = strings(path)
            assertFalse(values.keys.any { it.startsWith("system_control_snapshot") || it == "widget_time_unknown" })
            val result = String.format(Locale.forLanguageTag(language),
                values.getValue("widget_open_description"), "STATE", "MODE")
            assertTrue(result.contains("STATE") && result.contains("MODE"))
            assertFalse(result.contains("%"))
        }
    }
}

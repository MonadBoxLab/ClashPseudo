package io.github.monadboxlab.clashpseudo.backup

import androidx.test.platform.app.InstrumentationRegistry
import io.github.monadboxlab.clashpseudo.R
import org.junit.Assert.*
import org.junit.Test
import org.xmlpull.v1.XmlPullParser

class BackupRulesTest {
    private val businessPaths = BackupFiles.Kind.entries.map { "configurations/${it.fileName}" }.toSet()

    private fun rules(resource: Int): Map<String, List<Pair<String, String>>> {
        val result = linkedMapOf<String, MutableList<Pair<String, String>>>()
        InstrumentationRegistry.getInstrumentation().targetContext.resources.getXml(resource).use { xml ->
            var section = ""
            while (xml.eventType != XmlPullParser.END_DOCUMENT) {
                if (xml.eventType == XmlPullParser.START_TAG) {
                    when (xml.name) {
                        "full-backup-content", "cloud-backup", "device-transfer" -> {
                            section = xml.name
                            assertNull("Duplicate backup section", result.put(section, mutableListOf()))
                        }
                        "include" -> {
                            assertTrue("Include without backup section", section in result)
                            result.getValue(section) += xml.getAttributeValue(null, "domain") to
                                xml.getAttributeValue(null, "path")
                        }
                        "data-extraction-rules" -> Unit
                        else -> fail("Unexpected backup rule: ${xml.name}")
                    }
                }
                xml.next()
            }
        }
        return result
    }

    private fun assertOnlyBusinessFiles(sections: Map<String, List<Pair<String, String>>>) {
        for ((name, includes) in sections) {
            assertEquals("$name includes extra or duplicate files", 3, includes.size)
            assertEquals(businessPaths.map { "file" to it }.toSet(), includes.toSet())
            assertFalse(includes.any { (_, path) -> path.contains("privacy-notice-shown") })
        }
    }

    @Test fun api24FullBackupOnlyIncludesTheThreeBusinessFilesAndNotInstallationOrNoBackupMaterials() {
        val sections = rules(R.xml.backup_rules)
        assertEquals(setOf("full-backup-content"), sections.keys)
        assertOnlyBusinessFiles(sections)
    }

    @Test fun cloudAndDeviceTransferOnlyIncludeTheThreeBusinessFilesAndNotInstallationOrNoBackupMaterials() {
        val sections = rules(R.xml.data_extraction_rules)
        assertEquals(setOf("cloud-backup", "device-transfer"), sections.keys)
        assertOnlyBusinessFiles(sections)
    }
}

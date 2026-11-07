"""System backups include only saved configurations, not tasks, runtime inputs, or caches."""
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
MAIN = ROOT / "android/app/src/main"
TARGETS = {
    ("file", "configurations/configurations.json"),
    ("file", "configurations/preferences.json"),
    ("file", "configurations/overrides.json"),
}


class BackupRulesTest(unittest.TestCase):
    def assert_business_file_allowlist(self, section):
        # The complete allowlist excludes installation markers, runtime inputs, core files, and other backup domains.
        self.assertEqual(section.attrib, {})
        self.assertEqual(len(section), len(TARGETS))
        self.assertEqual(
            {(node.tag, node.attrib.get("domain"), node.attrib.get("path"))
             for node in section},
            {("include", domain, path) for domain, path in TARGETS},
        )
        for node in section:
            # Do not add requireFlags or other transport/encryption capability requirements.
            self.assertEqual(set(node.attrib), {"domain", "path"})
            self.assertEqual(len(node), 0)

    def test_modern_backup_and_transfer_have_exact_file_allowlist(self):
        rules = ET.parse(MAIN / "res/xml/data_extraction_rules.xml").getroot()
        self.assertEqual(rules.tag, "data-extraction-rules")
        self.assertEqual(rules.attrib, {})
        self.assertCountEqual(
            [section.tag for section in rules], ["cloud-backup", "device-transfer"]
        )
        for section in rules:
            with self.subTest(section=section.tag):
                self.assert_business_file_allowlist(section)

    def test_api24_full_backup_has_exact_business_file_allowlist(self):
        rules = ET.parse(MAIN / "res/xml/backup_rules.xml").getroot()
        self.assertEqual(rules.tag, "full-backup-content")
        self.assert_business_file_allowlist(rules)

    def test_api28_and_later_share_the_api24_rules_without_an_encryption_override(self):
        base = MAIN / "res/xml/backup_rules.xml"
        self.assertTrue(base.is_file())
        self.assertFalse((MAIN / "res/xml-v28/backup_rules.xml").exists())
        self.assertEqual(set((MAIN / "res").glob("xml*/backup_rules.xml")), {base})
        self.assert_business_file_allowlist(ET.parse(base).getroot())

    def test_manifest_selects_rules_and_storage_uses_matching_location(self):
        namespace = "{http://schemas.android.com/apk/res/android}"
        app = ET.parse(MAIN / "AndroidManifest.xml").getroot().find("application")
        self.assertEqual(app.attrib[namespace + "allowBackup"], "true")
        self.assertEqual(app.attrib[namespace + "backupAgent"], ".app.PseudoBackupAgent")
        self.assertEqual(app.attrib[namespace + "fullBackupOnly"], "true")
        self.assertEqual(app.attrib[namespace + "fullBackupContent"], "@xml/backup_rules")
        self.assertEqual(app.attrib[namespace + "dataExtractionRules"], "@xml/data_extraction_rules")
        paths = (MAIN / "kotlin/io/github/monadboxlab/clashpseudo/storage/AppFiles.kt").read_text()
        self.assertIn('File(context.filesDir, "configurations")', paths)
        self.assertRegex(
            paths, r'fun\s+work\(context:\s*Context\)\s*=\s*'
            r'File\(context\.noBackupFilesDir,\s*"work"\)'
        )
        self.assertRegex(
            paths, r'fun\s+runInput\(context:\s*Context,\s*owner:\s*String\)\s*=\s*'
            r'File\(work\(context\),\s*"run-input-\$owner\.json"\)'
        )
        self.assertRegex(
            paths, r'fun\s+privacyNotice\(context:\s*Context\)\s*=\s*'
            r'File\(context\.noBackupFilesDir,\s*"privacy-notice-shown"\)'
        )
        self.assertIn('File(context.noBackupFilesDir.canonicalFile, "mihomo")', paths)
        self.assertIn('File(context.noBackupFilesDir, "work/system-input.json")', paths)
        store = (ROOT / "lib/src/logic/configs/config_store.dart").read_text()
        self.assertIn('${directory.path}/configurations.json', store)


if __name__ == "__main__":
    unittest.main()

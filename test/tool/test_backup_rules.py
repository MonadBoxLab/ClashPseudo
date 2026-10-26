"""系统备份只覆盖已提交配置，不包括任务、运行输入或缓存。"""
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
    def test_modern_backup_and_transfer_have_exact_file_allowlist(self):
        rules = ET.parse(MAIN / "res/xml/data_extraction_rules.xml").getroot()
        cloud = rules.find("cloud-backup")
        self.assertEqual(cloud.attrib, {"disableIfNoEncryptionCapabilities": "true"})
        for section in (cloud, rules.find("device-transfer")):
            self.assertEqual(
                {(node.tag, node.attrib.get("domain"), node.attrib.get("path"))
                 for node in section},
                {("include", domain, path) for domain, path in TARGETS},
            )

    def test_android_9_backup_requires_client_encryption(self):
        rules = ET.parse(MAIN / "res/xml-v28/backup_rules.xml").getroot()
        self.assertEqual(
            {(node.tag, node.attrib.get("domain"), node.attrib.get("path"),
              node.attrib.get("requireFlags")) for node in rules},
            {("include", domain, path, "clientSideEncryption")
             for domain, path in TARGETS},
        )

    def test_older_devices_exclude_every_backup_domain(self):
        rules = ET.parse(MAIN / "res/xml/backup_rules.xml").getroot()
        domains = {"root", "file", "database", "sharedpref", "external",
                   "device_root", "device_file", "device_database", "device_sharedpref"}
        self.assertEqual({node.attrib["domain"] for node in rules}, domains)
        for node in rules:
            self.assertEqual(node.tag, "exclude")
            self.assertEqual(node.attrib["path"], ".")

    def test_manifest_selects_rules_and_storage_uses_matching_location(self):
        namespace = "{http://schemas.android.com/apk/res/android}"
        app = ET.parse(MAIN / "AndroidManifest.xml").getroot().find("application")
        self.assertEqual(app.attrib[namespace + "allowBackup"], "true")
        self.assertEqual(app.attrib[namespace + "backupAgent"], ".app.PseudoBackupAgent")
        self.assertEqual(app.attrib[namespace + "fullBackupOnly"], "true")
        self.assertEqual(app.attrib[namespace + "fullBackupContent"], "@xml/backup_rules")
        self.assertEqual(app.attrib[namespace + "dataExtractionRules"], "@xml/data_extraction_rules")
        paths = (MAIN / "kotlin/io/github/monadboxlab/clashpseudo/app/AppFiles.kt").read_text()
        self.assertIn('File(context.filesDir, "configurations")', paths)
        self.assertIn('File(context.noBackupFilesDir, "work/run-input-$owner.json")', paths)
        self.assertIn('File(context.noBackupFilesDir.canonicalFile, "mihomo")', paths)
        store = (ROOT / "lib/src/features/configs/config_store.dart").read_text()
        self.assertIn('${directory.path}/configurations.json', store)


if __name__ == "__main__":
    unittest.main()

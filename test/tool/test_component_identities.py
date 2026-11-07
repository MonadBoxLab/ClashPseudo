"""Verify that directory and responsibility changes preserve Android component names, background task identifiers, JNI entry points, and FlutterEngine entry names."""
import importlib.util
from pathlib import Path
import re
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
MAIN = ROOT / "android/app/src/main"
KOTLIN = MAIN / "kotlin/io/github/monadboxlab/clashpseudo"
PACKAGE = "io.github.monadboxlab.clashpseudo"
ANDROID = "{http://schemas.android.com/apk/res/android}"


class ComponentIdentitiesTest(unittest.TestCase):
    def test_manifest_keeps_installed_component_names_and_resolvable_classes(self):
        app = ET.parse(MAIN / "AndroidManifest.xml").getroot().find("application")
        self.assertEqual(app.get(ANDROID + "name"), ".app.PseudoApplication")
        self.assertEqual(app.get(ANDROID + "backupAgent"), ".app.PseudoBackupAgent")
        expected = {
            "activity": {".MainActivity"},
            "service": {".app.AppWorkService", ".app.VpnTileService", ".vpn.PseudoVpnService",
                        ".logic.AppRuntimeService", ".nativecore.CoreService"},
            "receiver": {".app.VpnWidgetProvider"},
        }
        names = {".app.PseudoApplication", ".app.PseudoBackupAgent"}
        for tag, components in expected.items():
            actual = {node.get(ANDROID + "name") for node in app.findall(tag)}
            self.assertEqual(actual, components)
            names.update(components)
        for name in names:
            with self.subTest(component=name):
                source = (KOTLIN / (name[1:].replace(".", "/") + ".kt")).read_text()
                parent, _, simple = (PACKAGE + name).rpartition(".")
                self.assertRegex(source, rf"(?m)^package {re.escape(parent)}$")
                self.assertRegex(source, rf"\bclass {simple}\b")
        services = {node.get(ANDROID + "name"): node for node in app.findall("service")}
        for name in (".nativecore.CoreService", ".vpn.PseudoVpnService"):
            self.assertEqual(services[name].get(ANDROID + "process"), ":core")
        for name in (".logic.AppRuntimeService", ".app.AppWorkService", ".app.VpnTileService"):
            self.assertIsNone(services[name].get(ANDROID + "process"))
        for name in (".nativecore.CoreService", ".logic.AppRuntimeService", ".app.AppWorkService"):
            self.assertEqual(services[name].get(ANDROID + "exported"), "false")
        self.assertEqual(services[".vpn.PseudoVpnService"].get(ANDROID + "permission"),
                         "android.permission.BIND_VPN_SERVICE")
        self.assertEqual(services[".nativecore.CoreService"].get(ANDROID + "foregroundServiceType"),
                         "connectedDevice")
        self.assertEqual(services[".app.AppWorkService"].get(ANDROID + "foregroundServiceType"),
                         "dataSync")
        self.assertEqual(services[".vpn.PseudoVpnService"].get(ANDROID + "foregroundServiceType"),
                         "systemExempted")

    def test_sdk_witness_is_a_self_target_test_entry_not_a_production_component(self):
        runner = PACKAGE + ".validation.SystemEntryInstrumentation"
        spec = importlib.util.spec_from_file_location("sdk_builder", ROOT / "tool/android/build_sdk_observer.py")
        assert spec is not None and spec.loader is not None
        builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(builder)
        manifest = ET.fromstring(builder.manifest(min_api=24, target_sdk=39))
        entries = manifest.findall("instrumentation")
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0].get(ANDROID + "name"), runner)
        self.assertEqual(entries[0].get(ANDROID + "targetPackage"), PACKAGE + ".test")
        self.assertEqual(entries[0].get(ANDROID + "handleProfiling"), "false")
        self.assertEqual(manifest.get("package"), PACKAGE + ".test")
        self.assertEqual(manifest.findall("uses-permission"), [])
        self.assertEqual(ET.parse(MAIN / "AndroidManifest.xml").getroot().findall("instrumentation"), [])
        source = (ROOT / "android/app/src/androidTest/java" /
                  (runner.replace(".", "/") + ".java")).read_text()
        for forbidden in ("NativeCore", "AppBridge", "java.net", "java.io.File", "tmp/", "controlled-local-"):
            self.assertNotIn(forbidden, source)
        self.assertIn('arguments.getString("allowUiAction")', source)
        self.assertIn('arguments.getString("expectedConfigName", "")', source)
        self.assertIn('getContext().getPackageName()', source)
        self.assertIn('getTargetContext().getPackageName()', source)

    def test_worker_class_and_unique_task_identities_survive_directory_moves(self):
        worker = (KOTLIN / "app/ScheduleWorker.kt").read_text()
        schedule = (KOTLIN / "schedule/ScheduleManager.kt").read_text()
        self.assertIn("package " + PACKAGE + ".app", worker)
        self.assertIn("class ScheduleWorker(", worker)
        self.assertIn("import " + PACKAGE + ".app.ScheduleWorker", schedule)
        self.assertIn("PeriodicWorkRequestBuilder<ScheduleWorker>", schedule)
        self.assertIn('"update-$kind-$id"', schedule)
        self.assertIn('"update-reconcile"', schedule)
        self.assertIn('PREFS = "update-schedules"', schedule)

    def test_native_class_and_jni_prefix_stay_paired(self):
        native = (KOTLIN / "nativecore/NativeCore.kt").read_text()
        bridge = (ROOT / "native/mihomo/bridge_android.c").read_text()
        self.assertIn("package " + PACKAGE + ".nativecore", native)
        self.assertIn("object NativeCore", native)
        methods = re.findall(r"\bexternal\s+fun\s+(\w+)\s*\(", native)
        self.assertEqual(methods, ["invoke"])
        prefix = "Java_" + PACKAGE.replace(".", "_") + "_nativecore_NativeCore_"
        exports = re.findall(rf"\b{re.escape(prefix)}(\w+)\s*\(", bridge)
        self.assertEqual(exports, methods)

    def test_background_entry_is_aot_retained_and_uses_the_same_channel(self):
        main = (ROOT / "lib/main.dart").read_text()
        host = (KOTLIN / "logic/LogicEngineHost.kt").read_text()
        native = (KOTLIN / "bridge/AppBridge.kt").read_text()
        dart = (ROOT / "lib/src/platform/channel/app_bridge.dart").read_text()
        self.assertIn("@pragma('vm:entry-point')\nvoid appBackgroundMain()", main)
        self.assertIn('"appBackgroundMain"', host)
        channel = "io.github.monadboxlab.clashpseudo/app"
        self.assertIn('CHANNEL = "' + channel + '"', native)
        self.assertIn("'" + channel + "'", dart)


if __name__ == "__main__":
    unittest.main()

"""Go、Pub 与 Maven 解析及实际版本核对。"""
import json
import os
from pathlib import Path
import re
import tempfile
from tool.common.io import fetch, require
from tool.common.process import run
from tool.dependencies.resources import prepare_bundled_assets
from tool.dependencies.legal import Legal
from tool.artifacts import verify_release_licenses as artifacts

MIHOMO = "github.com/metacubex/mihomo"


MAVEN = ("https://dl.google.com/dl/android/maven2", "https://repo.maven.apache.org/maven2")


MAVEN_DECLARATION = re.compile(
    r'(?P<prefix>\b(?:implementation|api|testImplementation|androidTestImplementation)\(")'
    r'(?P<name>[\w.-]+:[\w.-]+):(?P<version>[^"\s]+)(?P<suffix>"\))')


def mihomo_release():
    return json.loads(fetch("https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"))["tag_name"]


class Updater:
    def __init__(self, root, go="go", flutter="flutter", *, env=None):
        self.env = dict(env or {})
        self.root = Path(root)
        self.go = go
        self.flutter = flutter
        self.native = self.root / "native/mihomo"
        self.resolution = {"go": {}, "pub": {}, "android": {}}

    def run(self, command, cwd=None, env=None):
        return run(command, cwd or self.root, {**self.env, **(env or {})})

    def go_run(self, *arguments, env=None):
        return self.run([self.go, *arguments], self.native, env)

    def graph(self, output):
        output.write_text(self.go_run("list", "-mod=readonly", "-m", "-json", "all"), encoding="utf-8")
        return artifacts.go_modules(output)

    def go_updates(self, names, release=None):
        if not names:
            return {}
        manifest = json.loads(self.go_run("mod", "edit", "-json"))
        current = {entry["Path"]: entry["Version"] for entry in manifest["Require"]}
        require(set(names) <= current.keys(), "只能选择现有 Go 依赖：" + repr(sorted(set(names) - current.keys())))
        updates = {}
        for name in names:
            if name == MIHOMO:
                target = release or mihomo_release()
            else:
                module = json.loads(self.go_run("list", "-mod=readonly", "-m", "-u", "-json", name))
                # Go 的 Update 字段已按模块版本规则选择较新版本，包括 pseudo-version。
                target = module.get("Update", {}).get("Version", current[name])
            self.resolution["go"][name] = {"previous": current[name], "selected": target}
            if target != current[name]:
                updates[name] = target
        return updates

    def update_go(self, updates):
        before = json.loads(self.go_run("mod", "edit", "-json"))
        if updates:
            self.go_run("get", *[name + "@" + version for name, version in sorted(updates.items())])
        self.go_run("mod", "tidy")
        self.go_run("mod", "verify")
        after = json.loads(self.go_run("mod", "edit", "-json"))
        require(before.get("Replace") == after.get("Replace"),
                "Go replace 发生变化；保留原 replace，完成所选依赖的来源与许可复核")
        new = {row["Path"]: row["Version"] for row in after["Require"]}
        for name in ("github.com/rasky/go-lzo", "github.com/metacubex/chacha"):
            require(name in new, "许可版本约束丢失：" + name)
        for name in updates:
            self.resolution["go"].setdefault(name, {})["selected"] = new.get(name)

    def pub_updates(self, names=()):
        self.run([self.flutter, "pub", "get"], self.root)
        result = json.loads(self.run([self.flutter, "pub", "outdated", "--json", "--show-all"], self.root))
        packages = {row["package"]: row for row in result["packages"]}
        resolved = json.loads(self.run([self.flutter, "pub", "deps", "--json"], self.root))
        hosted = {row["name"] for row in resolved["packages"] if row.get("source") == "hosted"}
        names = names or [row["package"] for row in result["packages"]
                          if row.get("kind") in ("direct", "dev") and row["package"] in hosted]
        updates = {}
        for name in names:
            row = packages.get(name)
            require(row and row.get("kind") in ("direct", "dev") and name in hosted,
                    "只能选择现有 hosted 直接依赖：" + name)
            version = (row.get("resolvable") or {}).get("version")
            require(version, "当前 SDK 下缺少可解析版本：" + name)
            self.resolution["pub"][name] = {"current": row.get("current"), "latest": row.get("latest"),
                                             "selected": version, "kind": row["kind"]}
            current = (row.get("current") or {}).get("version")
            if version != current:
                updates[name] = (version, row["kind"])
        return updates

    def update_pub(self, updates):
        if not updates:
            return
        descriptors = [("dev:" if kind == "dev" else "") + name + "@" + version
                       for name, (version, kind) in sorted(updates.items())]
        self.run([self.flutter, "pub", "add", "--no-example", *descriptors], self.root)
        resolved = json.loads(self.run([self.flutter, "pub", "deps", "--json"], self.root))
        versions = {row["name"]: row["version"] for row in resolved["packages"]}
        for name in updates:
            self.resolution["pub"].setdefault(name, {})["selected"] = versions[name]
            updates[name] = (versions[name], updates[name][1])
        self.run([self.flutter, "pub", "get", "--enforce-lockfile"], self.root)

    def android_updates(self, names):
        if not names:
            return {}
        path = self.root / "android/app/build.gradle.kts"
        text = path.read_text(encoding="utf-8")
        declarations = {match["name"]: match for match in MAVEN_DECLARATION.finditer(text)}
        require(set(names) <= declarations.keys(), "只能选择现有 Android 库：" + repr(sorted(set(names) - declarations.keys())))
        configurations = {}
        for name in names:
            declaration = declarations[name]
            kind = declaration["prefix"].split("(", 1)[0]
            configuration = {"testImplementation": "debugUnitTestRuntimeClasspath",
                             "androidTestImplementation": "debugAndroidTestRuntimeClasspath"}.get(kind, "releaseRuntimeClasspath")
            configurations.setdefault(configuration, []).append(name)
        self.run([self.flutter, "pub", "get", "--enforce-lockfile"], self.root)
        try:
            self.update_android(dict.fromkeys(names, "latest.release"))
            with tempfile.TemporaryDirectory(prefix="clash-gradle-resolution-") as temporary:
                script = Path(temporary) / "resolve.gradle"
                script.write_text(
                    "def requests = new groovy.json.JsonSlurper().parseText(" + json.dumps(json.dumps(configurations)) + ")\n"
                    + """gradle.projectsEvaluated {
    def app = gradle.rootProject.findProject(':app')
    if (app == null) return
    app.tasks.register('clashDependencyUpdates') {
        doLast {
            def selected = [:]
            requests.each { configuration, names ->
                def resolved = app.configurations.getByName(configuration).resolvedConfiguration
                resolved.rethrowFailure()
                resolved.lenientConfiguration.allModuleDependencies.each { dependency ->
                    def name = dependency.moduleGroup + ':' + dependency.moduleName
                    if (names.contains(name)) selected[name] = dependency.moduleVersion
                }
            }
            println('CLASH_DEPENDENCIES=' + groovy.json.JsonOutput.toJson(selected))
        }
    }
}
""", encoding="utf-8")
                output = self.run([self.env.get("CLASH_GRADLE", self.root / "android/gradlew"), "-p", self.root / "android",
                                   "--console=plain", "--init-script", script, ":app:clashDependencyUpdates"], self.root)
            selected = json.loads(next(line.removeprefix("CLASH_DEPENDENCIES=") for line in output.splitlines()
                                       if line.startswith("CLASH_DEPENDENCIES=")))
            updates = {}
            for name in names:
                previous, version = declarations[name]["version"], selected[name]
                self.resolution["android"][name] = {"previous": previous, "selected": version}
                if version != previous:
                    updates[name] = version
            return updates
        finally:
            path.write_text(text, encoding="utf-8")

    def update_android(self, updates):
        path = self.root / "android/app/build.gradle.kts"
        text = path.read_text(encoding="utf-8")
        text = MAVEN_DECLARATION.sub(
            lambda m: m["prefix"] + m["name"] + ":" + updates.get(m["name"], m["version"]) + m["suffix"], text)
        path.write_text(text, encoding="utf-8")

    def android_graph(self):
        self.run([self.flutter, "pub", "get", "--enforce-lockfile"], self.root)
        return self.run([self.env.get("CLASH_GRADLE", os.environ.get("CLASH_GRADLE", self.root / "android/gradlew")), "-p", self.root / "android", "--console=plain",
                    ":app:dependencies", "--configuration", "releaseRuntimeClasspath"], self.root)

    def legal(self, temporary):
        return Legal(self, temporary, fetch, self.run, artifacts)

    def evidence(self, output):
        """生成Go模块图、Android依赖报告和Flutter NOTICES，保存为APK核验输入。"""
        prepare_bundled_assets(self.root)
        output.mkdir()
        self.graph(output / "go-modules.json")
        (output / "android-dependencies.txt").write_text(self.android_graph(), encoding="utf-8")
        assets = output / "flutter-assets"
        self.run([self.flutter, "build", "bundle", "--release", "--no-pub", "--target-platform=android-arm64",
             "--asset-dir", assets], self.root)
        import gzip
        notices = gzip.decompress((assets / "NOTICES.Z").read_bytes())
        (output / "NOTICES").write_bytes(notices)

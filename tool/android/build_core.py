"""使用 NDK 构建 Android 原生库，完成编译后替换对应 ABI 的产物。"""
import argparse
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
ABI_TARGETS = {
    "armeabi-v7a": ("arm", "armv7a-linux-androideabi"),
    "arm64-v8a": ("arm64", "aarch64-linux-android"),
    "x86_64": ("amd64", "x86_64-linux-android"),
}


def api_level(value):
    if not re.fullmatch(r"[0-9]+", str(value)) or int(value) < 24:
        raise argparse.ArgumentTypeError("Android API 必须为至少 24 的整数")
    return int(value)


def abi_list(value):
    values = value.split(",") if isinstance(value, str) else list(value)
    if not values or any(abi not in ABI_TARGETS for abi in values):
        raise argparse.ArgumentTypeError("ABI 必须为逗号分隔的 armeabi-v7a、arm64-v8a 或 x86_64")
    return list(dict.fromkeys(values))


def build(project, ndk, api, output, abis, *, coverage=False, env=None):
    project, ndk, output = Path(project).resolve(), Path(ndk).resolve(), Path(output).absolute()
    api, abis = api_level(api), abi_list(abis)
    if not (project / "pubspec.yaml").is_file() or not (project / "native/mihomo/go.mod").is_file():
        raise ValueError("缺少应用项目目录")
    if (platform.system(), platform.machine()) != ("Linux", "x86_64"):
        raise ValueError("原生构建只支持 Linux x86_64，不自动安装工具链")
    environment = dict(os.environ if env is None else env)
    go = shutil.which("go", path=environment.get("PATH", os.defpath))
    if go is None:
        raise ValueError("找不到 Go 可执行文件")
    compilers = {
        abi: ndk / "toolchains/llvm/prebuilt/linux-x86_64/bin" / f"{ABI_TARGETS[abi][1]}{api}-clang"
        for abi in abis
    }
    for compiler in compilers.values():
        if not compiler.is_file() or not os.access(compiler, os.X_OK):
            raise ValueError("缺少 NDK 编译器：" + str(compiler))
    from tool.contracts.generate import generate
    generate(project, check=True, env=environment)
    environment.update(GOTOOLCHAIN="local", CGO_ENABLED="1", GOOS="android")
    native = project / "native/mihomo"
    version = subprocess.run(
        [go, "-C", str(native), "list", "-mod=readonly", "-m", "-f", "{{.Version}}", "github.com/metacubex/mihomo"],
        env=environment, check=True, stdout=subprocess.PIPE, stderr=sys.stderr, text=True,
    ).stdout.strip()
    libraries = []
    for abi in abis:
        current = dict(environment)
        current.pop("GOARM", None)
        current.update(GOARCH=ABI_TARGETS[abi][0], CC=str(compilers[abi]))
        if abi == "armeabi-v7a":
            current["GOARM"] = "7"
        destination = output / abi
        destination.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=".staging.", dir=destination) as temporary:
            staging = Path(temporary)
            link_flags = "-Wl,-z,max-page-size=16384"
            if coverage:
                profile = staging / "profile-list.txt"
                profile.write_text("src:bridge_android.c\nsrc:*/bridge_android.c\nsrc:*/coverage_probe.c\n")
                flags = ["-fprofile-instr-generate", "-fcoverage-mapping", "-fprofile-update=atomic", "-fcoverage-mcdc"]
                probe = staging / "coverage_probe.o"
                subprocess.run([current["CC"], *flags, "-c",
                                str(project / "android/app/src/androidTest/cpp/coverage_probe.c"),
                                "-o", str(probe)], env=current, check=True, stdout=sys.stderr, stderr=sys.stderr)
                current["CGO_CFLAGS"] = (environment.get("CGO_CFLAGS", "") + " " + " ".join(flags)
                                         + " " + _go_quote("-fprofile-list=" + str(profile))).strip()
                current["CGO_LDFLAGS"] = (environment.get("CGO_LDFLAGS", "") + " -fprofile-instr-generate").strip()
                link_flags += " " + _go_quote(str(probe))
            library = staging / "libmihomo_bridge.so"
            subprocess.run(
                [go, "-C", str(native), "build", "-mod=readonly", "-trimpath", "-tags", "cmfa,with_gvisor",
                 "-buildmode=c-shared", "-ldflags",
                 f"-X clashpseudo/native/internal/engine.Version={version} -extldflags {_go_quote(link_flags)}",
                 "-o", str(library), "."], env=current, check=True, stdout=sys.stderr, stderr=sys.stderr)
            target = destination / library.name
            os.replace(library, target)
            libraries.append(target)
    return libraries


def _go_quote(value):
    # Go 的 quoted.Split 接受整段单引号或双引号，不采用 shell 转义。
    if "'" not in value:
        return "'" + value + "'"
    if '"' not in value:
        return '"' + value + '"'
    raise ValueError("Go 编译参数不能同时包含单引号和双引号")


def register_parser(subparsers):
    parser = subparsers.add_parser(
        "build-core", help="构建 Android 三种 ABI 的原生库",
        description="生成 libmihomo_bridge.so；逐 ABI 在 staging 完成编译后替换旧库，不修改依赖输入。",
        epilog="示例：android build-core --ndk /opt/android/ndk/30 --output /tmp/native-libs")
    parser.add_argument("--project", type=Path, default=ROOT, help="应用项目目录")
    parser.add_argument("--ndk", type=Path, required=True, help="Android NDK 目录")
    parser.add_argument("--api", type=api_level, default=24, help="Android API 级别")
    parser.add_argument("--output", type=Path, required=True, help="原生库输出目录，按 ABI 建立子目录")
    parser.add_argument("--abis", type=abi_list, default=list(ABI_TARGETS), help="逗号分隔的 ABI 列表，默认三种 ABI")
    parser.add_argument("--coverage", action="store_true", help="添加 JNI coverage，仅用于测试构建")
    parser.set_defaults(handler=run)


def run(args):
    libraries = build(args.project, args.ndk, args.api, args.output, args.abis, coverage=args.coverage)
    return {"libraries": [str(path) for path in libraries]}

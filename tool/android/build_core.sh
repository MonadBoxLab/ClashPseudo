#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 4 || $# -gt 5 || ( $# -eq 5 && "${5:-}" != coverage ) ]]; then
  printf 'Usage: %s NDK_PATH API_LEVEL OUTPUT_DIRECTORY ABI_LIST [coverage]\n' "$0" >&2
  exit 2
fi
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ -f "$root/pubspec.yaml" && -f "$root/native/mihomo/go.mod" ]] || {
  printf 'Application project root is missing.\n' >&2
  exit 2
}
ndk="$1"
api="$2"
out="$3"
[[ "$out" = /* ]] || out="$PWD/$out"
abis="$4"
coverage="${5:-}"
[[ "$api" =~ ^[0-9]+$ && "$api" -ge 24 ]] || {
  printf 'API level must be an integer of at least 24.\n' >&2
  exit 2
}
[[ "$abis" =~ ^(armeabi-v7a|arm64-v8a|x86_64)(,(armeabi-v7a|arm64-v8a|x86_64))*$ ]] || {
  printf 'ABI list must contain supported, comma-separated ABI names.\n' >&2
  exit 2
}
python3 -I "$root/tool/contracts/generate.py" --check
base_cflags="${CGO_CFLAGS:-}"
base_ldflags="${CGO_LDFLAGS:-}"
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) host=linux-x86_64 ;;
  *) printf 'Unsupported build host; no tools will be installed.\n' >&2; exit 2 ;;
esac
command -v go >/dev/null || { printf 'Go is required.\n' >&2; exit 2; }
export GOTOOLCHAIN=local CGO_ENABLED=1 GOOS=android
version="$(go -C "$root/native/mihomo" list -mod=readonly -m -f '{{.Version}}' github.com/metacubex/mihomo)"
for abi in ${abis//,/ }; do
  unset GOARM
  case "$abi" in
    armeabi-v7a) export GOARCH=arm GOARM=7; target=armv7a-linux-androideabi ;;
    arm64-v8a) export GOARCH=arm64; target=aarch64-linux-android ;;
    x86_64) export GOARCH=amd64; target=x86_64-linux-android ;;
  esac
  export CC="$ndk/toolchains/llvm/prebuilt/$host/bin/${target}${api}-clang"
  [[ -x "$CC" ]] || { printf 'Missing NDK compiler: %s\n' "$CC" >&2; exit 2; }
  destination="$out/$abi"
  mkdir -p "$destination"
  staging="$(mktemp -d "$destination/.staging.XXXXXX")"
  trap 'rm -rf -- "$staging"' EXIT
  link_flags="-Wl,-z,max-page-size=16384"
  if [[ "$coverage" == coverage ]]; then
    printf '%s\n' 'src:bridge_android.c' 'src:*/bridge_android.c' 'src:*/coverage_probe.c' \
      > "$staging/profile-list.txt"
    flags="-fprofile-instr-generate -fcoverage-mapping -fprofile-update=atomic -fcoverage-mcdc"
    "$CC" $flags -c "$root/android/app/src/androidTest/cpp/coverage_probe.c" \
      -o "$staging/coverage_probe.o"
    export CGO_CFLAGS="$base_cflags $flags -fprofile-list=$staging/profile-list.txt"
    export CGO_LDFLAGS="$base_ldflags -fprofile-instr-generate"
    link_flags="$link_flags $staging/coverage_probe.o"
  fi
  go -C "$root/native/mihomo" build -mod=readonly -trimpath -tags cmfa,with_gvisor \
    -buildmode=c-shared -ldflags "-X clashpseudo/native/internal/engine.Version=$version -extldflags '$link_flags'" \
    -o "$staging/libmihomo_bridge.so" .
  mv -- "$staging/libmihomo_bridge.so" "$destination/libmihomo_bridge.so"
  rm -rf -- "$staging"
  trap - EXIT
done

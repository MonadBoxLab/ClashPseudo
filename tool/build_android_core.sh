#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  printf 'Usage: %s NDK_PATH API_LEVEL OUTPUT_DIRECTORY ABI_LIST\n' "$0" >&2
  exit 2
fi
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ndk="$1"
api="$2"
out="$3"
abis="$4"
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) host=linux-x86_64 ;;
  *) printf 'Unsupported build host; no tools will be installed.\n' >&2; exit 2 ;;
esac
command -v go >/dev/null || { printf 'Go is required.\n' >&2; exit 2; }
export GOTOOLCHAIN=local CGO_ENABLED=1 GOOS=android
version="$(go -C "$root/native/mihomo" list -mod=readonly -m -f '{{.Version}}' github.com/metacubex/mihomo)"
for abi in ${abis//,/ }; do
  case "$abi" in
    arm64-v8a) export GOARCH=arm64; target=aarch64-linux-android ;;
    x86_64) export GOARCH=amd64; target=x86_64-linux-android ;;
    *) printf 'Unsupported ABI: %s\n' "$abi" >&2; exit 2 ;;
  esac
  export CC="$ndk/toolchains/llvm/prebuilt/$host/bin/${target}${api}-clang"
  [[ -x "$CC" ]] || { printf 'Missing NDK compiler: %s\n' "$CC" >&2; exit 2; }
  destination="$out/$abi"
  mkdir -p "$destination"
  staging="$(mktemp -d "$destination/.staging.XXXXXX")"
  trap 'rm -rf -- "$staging"' EXIT
  go -C "$root/native/mihomo" build -mod=readonly -trimpath -tags cmfa \
    -buildmode=c-shared -ldflags "-X clashpseudo/native/internal/engine.Version=$version -extldflags=-Wl,-z,max-page-size=16384" \
    -o "$staging/libmihomo_bridge.so" .
  mv -- "$staging/libmihomo_bridge.so" "$destination/libmihomo_bridge.so"
  rm -rf -- "$staging"
  trap - EXIT
done

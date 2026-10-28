#!/usr/bin/env bash
# Build rclone as a static library for iOS and package it as an XCFramework.
#
# Produces deps/frameworks/Rclone.xcframework with two slices:
#   ios-arm64            (device)
#   ios-arm64-simulator  (simulator)
#
# The simulator slice matters: libish_emu.a is device-only, which already
# prevents building this app for the Simulator. rclone must not become a
# SECOND reason — if the iSH constraint is ever lifted, this should not be
# what blocks it.
#
# Which backends get linked is decided by deps/rclone-mobile/backends/backends.go,
# not here. rclone itself is a go.mod dependency (pinned version), never
# vendored — upgrading is a one-line change to that file.
#
# The same archive carries the embedded Tailscale node (deps/rclone-mobile/tsnet):
# one process cannot link two Go c-archives (two Go runtimes). GO_TAGS trims
# Tailscale features at build time; the default:
#   ts_omit_logtail    never upload logs to log.tailscale.com
#   ts_omit_portmapper no UPnP / NAT-PMP / PCP to the LAN gateway, so iOS shows
#                      no Local Network permission prompt (NAT traversal then
#                      relies on STUN + DERP)
# Do NOT add ts_omit_acme: tsnet does not compile without it.
# Override with GO_TAGS="" (nothing omitted) or your own comma-separated list.
set -euo pipefail

GO_TAGS="${GO_TAGS-ts_omit_logtail,ts_omit_portmapper}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/deps/rclone-mobile"
OUT="$ROOT/deps/frameworks"
BUILD="$ROOT/deps/build/rclone"

command -v go >/dev/null || { echo "error: go toolchain not found" >&2; exit 1; }

mkdir -p "$BUILD" "$OUT"
cd "$SRC"

build_slice() {
  local sdk="$1" minflag="$2" tag="$3"
  echo "==> $tag"
  CC="$(xcrun --sdk "$sdk" -f clang) -isysroot $(xcrun --sdk "$sdk" --show-sdk-path) $minflag -arch arm64" \
  CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
    go build -buildmode=c-archive -trimpath -ldflags="-s -w" ${GO_TAGS:+-tags "$GO_TAGS"} \
      -o "$BUILD/$tag/librclone.a" ./librclone
}

echo "==> $(go version) tags='${GO_TAGS}'"

build_slice iphoneos          "-miphoneos-version-min=16.0"        device
build_slice iphonesimulator   "-mios-simulator-version-min=16.0"   simulator

# c-archive emits librclone.h next to each .a; both slices share one header.
for t in device simulator; do
  mkdir -p "$BUILD/$t/include"
  mv "$BUILD/$t/librclone.h" "$BUILD/$t/include/" 2>/dev/null || true
done

rm -rf "$OUT/Rclone.xcframework"
xcodebuild -create-xcframework \
  -library "$BUILD/device/librclone.a"    -headers "$BUILD/device/include" \
  -library "$BUILD/simulator/librclone.a" -headers "$BUILD/simulator/include" \
  -output "$OUT/Rclone.xcframework" >/dev/null

echo "==> $OUT/Rclone.xcframework"
du -sh "$OUT/Rclone.xcframework" | awk '{print "    size:", $1}'

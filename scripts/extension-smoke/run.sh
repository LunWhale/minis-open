#!/bin/bash
# run_extension_smoke.sh — compile the REAL ExtensionJSRuntime.swift against
# test stubs and run the extension-runtime smoke test.
#
# Usage:
#   ./scripts/extension-smoke/run.sh            # from anywhere
#
# What it checks (see main.swift for the full list):
#   Part A — runtime API: variadic minis.log, async command/tool results,
#            request interception (patch / in-place / async / clear),
#            store, settings, event hooks.
#   Part B — example plugins loaded from the repo with the real runtime:
#            examples/request-interceptor, examples/demo-extension,
#            extensions/opencode-go-relay (regression guard).
#
# Exits non-zero if any check fails. Requires Xcode CLT (swiftc) + macOS
# JavaScriptCore (both present on any dev machine that can build the app).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"

RUNTIME="$REPO/src/ios/Agent/Extension/ExtensionJSRuntime.swift"
if [ ! -f "$RUNTIME" ]; then
    echo "error: $RUNTIME not found (run from the repo)" >&2
    exit 1
fi

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

cp "$RUNTIME" "$BUILD_DIR/ExtensionJSRuntime.swift"
cp "$DIR/stubs.swift" "$BUILD_DIR/stubs.swift"
cp "$DIR/main.swift" "$BUILD_DIR/main.swift"

echo "• compiling smoke test (real runtime + stubs)…"
xcrun swiftc -O "$BUILD_DIR/stubs.swift" "$BUILD_DIR/ExtensionJSRuntime.swift" "$BUILD_DIR/main.swift" \
    -o "$BUILD_DIR/smoke" 2>&1 | grep -v "warning:" || true

if [ ! -x "$BUILD_DIR/smoke" ]; then
    echo "error: compilation failed" >&2
    exit 1
fi

echo "• running smoke test…"
"$BUILD_DIR/smoke" "$REPO"

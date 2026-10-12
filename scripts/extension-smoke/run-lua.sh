#!/bin/bash
# run-lua.sh — compile the REAL ExtensionLuaRuntime.swift (plus the vendored
# Lua 5.4 C sources) against test stubs and run the Lua runtime smoke test.
#
# Usage:
#   ./scripts/extension-smoke/run-lua.sh        # from anywhere
#
# What it checks (see lua/main.swift for the full list):
#   - the lua-demo status.lua command runs and forwards positional args
#     (cmd + timeout) to the shell bridge
#   - minis.api.file is a table with read/write/list/delete (positional and
#     table-call forms)
#   - minis.api.permission.request(kind) returns a boolean
#   - minis.api.settings get/set/all work positionally
#   - a registered tool receives its args table
#
# Exits non-zero if any check fails. Requires Xcode CLT (clang + swiftc).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"

EXT_DIR="$REPO/src/ios/Agent/Extension"
LUA_SRC="$EXT_DIR/Lua"
for f in "$EXT_DIR/ExtensionJSRuntime.swift" "$EXT_DIR/ExtensionLuaRuntime.swift" "$LUA_SRC/lua.h"; do
    if [ ! -f "$f" ]; then
        echo "error: $f not found (run from the repo)" >&2
        exit 1
    fi
done

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

# 1. Compile the vendored Lua C sources for macOS (lua.c / luac.c are the
# standalone interpreter REPLs and ship their own main() — exclude them).
echo "• compiling vendored Lua 5.4 sources…"
mkdir -p "$BUILD_DIR/lua"
for src in "$LUA_SRC"/*.c; do
    base="$(basename "$src")"
    case "$base" in
        lua.c|luac.c) continue ;;
    esac
    clang -O1 -c -DLUA_USE_MACOSX "$src" -o "$BUILD_DIR/lua/${base%.c}.o"
done

# 2. Compile the Swift harness against the real runtime sources.
echo "• compiling Lua smoke test (real runtime + stubs)…"
cp "$EXT_DIR/ExtensionJSRuntime.swift" "$BUILD_DIR/"
cp "$EXT_DIR/ExtensionLuaRuntime.swift" "$BUILD_DIR/"
cp "$DIR/stubs.swift" "$BUILD_DIR/"
cp "$DIR/lua/main.swift" "$BUILD_DIR/"

xcrun swiftc -O "$BUILD_DIR/stubs.swift" "$BUILD_DIR/ExtensionJSRuntime.swift" \
    "$BUILD_DIR/ExtensionLuaRuntime.swift" "$BUILD_DIR/main.swift" \
    "$BUILD_DIR"/lua/*.o -o "$BUILD_DIR/lua-smoke" 2>&1 | grep -v "warning:" || true

if [ ! -x "$BUILD_DIR/lua-smoke" ]; then
    echo "error: compilation failed" >&2
    exit 1
fi

# 3. Run.
echo "• running Lua smoke test…"
"$BUILD_DIR/lua-smoke" "$REPO"

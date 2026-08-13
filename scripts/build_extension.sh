#!/bin/bash
# build_extension.sh — package an extension folder into a .minisx zip.
#
# Usage:
#   ./scripts/build_extension.sh <source-dir> [output-path]
#
# Examples:
#   ./scripts/build_extension.sh examples/demo-extension examples/demo-extension.minisx
#   ./scripts/build_extension.sh my-extension            # → my-extension.minisx
set -euo pipefail

SRC="${1:?usage: build_extension.sh <source-dir> [output-path]}"
SRC="$(cd "$SRC" && pwd)"

if [ ! -f "$SRC/manifest.json" ]; then
    echo "error: $SRC/manifest.json not found" >&2
    exit 1
fi

if [ -n "${2:-}" ]; then
    OUT="$2"
else
    OUT="$(basename "$SRC").minisx"
fi

# Validate minimal manifest fields with python3 (if available).
if command -v python3 &>/dev/null; then
    python3 - "$SRC/manifest.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
for f in ("id", "name", "version", "kinds", "permissions"):
    if f not in m:
        sys.exit(f"error: manifest missing '{f}'")
print(f"✓ manifest ok: {m['name']} v{m['version']} ({', '.join(m['kinds'])})")
PY
fi

OUT="$(cd "$(dirname "$OUT")" 2>/dev/null && pwd)/$(basename "$OUT")"
cd "$SRC"
zip -r "$OUT" . -x ".*" > /dev/null
echo "✓ packaged: $OUT ($(du -h "$OUT" | cut -f1))"

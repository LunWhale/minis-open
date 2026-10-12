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

command -v python3 >/dev/null || { echo "error: python3 is required (macOS ships it with Xcode CLT)" >&2; exit 1; }

# Validate minimal manifest fields + package the archive.
python3 - "$SRC" "$OUT" <<'PY'
import json, os, sys, zipfile

src, out = sys.argv[1], sys.argv[2]
manifest_path = os.path.join(src, "manifest.json")
manifest_text = open(manifest_path, "r", encoding="utf-8").read()
m = json.loads(manifest_text)
for f in ("id", "name", "version", "kinds", "permissions"):
    if f not in m:
        sys.exit(f"error: manifest missing '{f}'")
print(f"✓ manifest ok: {m['name']} v{m['version']} ({', '.join(m['kinds'])})")

# Compatibility entry for installer builds that drop the manifest: every
# entry whose prefix-stripped name equals exactly "manifest.json" is skipped,
# but "<bundle>/x/../manifest.json" normalizes to the bundle root at the
# filesystem level while dodging that exact-match check. Including it keeps
# the same archive loadable on both old and fixed installers.
COMPAT_MANIFEST_ENTRY = "x/../manifest.json"

with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as archive:
    for root, dirs, files in os.walk(src):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for name in sorted(files):
            if name.startswith("."):
                continue
            full = os.path.join(root, name)
            rel = os.path.relpath(full, src)
            archive.write(full, rel)
    archive.writestr(COMPAT_MANIFEST_ENTRY, manifest_text)
print(f"✓ packaged: {out} ({os.path.getsize(out) / 1024:.1f}K)")
PY

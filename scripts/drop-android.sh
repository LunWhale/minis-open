#!/bin/bash
#
# drop-android.sh — keep this fork iOS-only.
#
# This repository is a fork of OpenMinis that intentionally ships **iOS only**.
# Upstream still carries an Android app, so every upstream merge re-introduces
# the Android tree. Run this script after each merge to drop it again.
#
# It removes only Android-platform files. It never touches `src/shared/`
# (the bashism rules are a real iOS bundle resource) or any iOS source.
#
# Usage:
#   ./scripts/drop-android.sh            # delete
#   ./scripts/drop-android.sh --dry-run  # show what would be deleted
#   ./scripts/drop-android.sh --check    # exit 1 if any Android part is present
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

MODE="delete"
case "${1:-}" in
    --dry-run) MODE="dry-run" ;;
    --check)   MODE="check" ;;
    "")        MODE="delete" ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
esac

# Directories and files that belong to the Android platform only.
ANDROID_PATHS=(
    "src/android"
    "deps/proot"
    "deps/talloc"
    "deps/build_proot.sh"
    "deps/build_rclone_android.sh"
    "deps/rclone-mobile/gomobile"
    "scripts/check_android_locale.py"
    "scripts/gen_debug_skill_android.sh"
    "scripts/prepare_android_sandbox.sh"
    "assets/badge-android.svg"
)

present=()
for p in "${ANDROID_PATHS[@]}"; do
    if [ -e "$p" ] || git ls-files --error-unmatch "$p" >/dev/null 2>&1; then
        present+=("$p")
    fi
done

if [ "$MODE" = "check" ]; then
    if [ ${#present[@]} -eq 0 ]; then
        echo "✅ iOS-only: no Android platform files present."
        exit 0
    fi
    echo "❌ Android platform files present (${#present[@]}):"
    printf '   %s\n' "${present[@]}"
    exit 1
fi

if [ ${#present[@]} -eq 0 ]; then
    echo "✅ Nothing to do — the Android tree is already gone."
    exit 0
fi

echo "Android platform files to remove (${#present[@]}):"
printf '   %s\n' "${present[@]}"

if [ "$MODE" = "dry-run" ]; then
    echo ""
    echo "(dry run — nothing was deleted)"
    exit 0
fi

# 1. Remove the Android platform from the index + working tree.
#    -f is required because upstream merges can leave locally-modified files
#    in the tree (we do not keep any Android edits of our own).
for p in "${present[@]}"; do
    # `git rm` fails when the path is already gone from the working tree, so
    # fall back to --cached, then to plain rm for anything untracked.
    git rm -r -f -q "$p" 2>/dev/null \
        || git rm -r -f -q --cached "$p" 2>/dev/null \
        || true
    rm -rf -- "$p"
done

# 2. Drop the `deps/proot` submodule stanza from .gitmodules, if a merge
#    brought it back. `git rm` needs .gitmodules clean to drop a submodule.
if git config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null | grep -q 'deps/proot'; then
    git config -f .gitmodules --remove-section 'submodule.deps/proot' 2>/dev/null || true
    git add .gitmodules
    echo "removed submodule.deps/proot from .gitmodules"
fi

echo ""
echo "✅ Android tree removed. Review with: git status"
echo "   Then commit, and make sure .gitignore has no src/android entries left."

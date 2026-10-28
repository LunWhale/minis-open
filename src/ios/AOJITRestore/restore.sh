#!/bin/sh
# [T-aojit-restore] AOJIT fallback: put musl or busybox back to the build
# bundled with Minis, when the installed build matches none of the AOT images
# linked into the app. Run by the app (AOJITSettingsModel.restore) after the
# user confirmed; the .apk files next to this script are the original signed
# Alpine 3.21.0 packages (the Alpine repository no longer carries them).
#
# usage: restore.sh <dir with the bundled .apk files> <package>...
#
# Safety, in order; nothing is changed until step 4:
#   1. only packages that are installed and differ from the bundled build
#   2. fetch the INSTALLED builds from the repository into a rollback dir;
#      without them there is no way back, so stop
#   3. apk add --simulate: stop unless every step is a downgrade / upgrade /
#      replace of one of these packages (no install, no removal of others)
#   4. apk add the bundled files, then check that busybox and apk still run
#   5. on any failure, apk add the rollback files and check again
# `apk add <file>` pins each package by checksum in /etc/apk/world; the world
# file is put back afterwards, so later installs and upgrades are not held
# back (the next `apk upgrade` may replace the restored build again).
#
# exit: 0 restored, 1 nothing to do, 10 usage, 11 rollback unavailable,
#       12 simulation refused, 13 failed and rolled back,
#       14 failed and the rollback failed too
set -u
[ $# -ge 2 ] || { echo "usage: restore.sh <apk dir> <package>..."; exit 10; }
SRC=$1; shift
ROLLBACK=/var/cache/minis-aojit/rollback
DB=/lib/apk/db/installed

installed_version() {
    awk -v p="$1" '/^P:/ { n = substr($0, 3) } /^V:/ { if (n == p) { print substr($0, 3); exit } }' "$DB"
}
healthy() {
    /bin/busybox true && /bin/sh -c true && apk --version > /dev/null
}

# 1. what to change
files=""; names=""; pins=""
for p in "$@"; do
    have=$(installed_version "$p")
    [ -n "$have" ] || continue
    apkfile=$(ls "$SRC/$p"-[0-9]*.apk 2> /dev/null | head -n 1)
    [ -n "$apkfile" ] || { echo "missing bundled package for $p"; exit 10; }
    want=${apkfile##*/$p-}; want=${want%.apk}
    [ "$have" = "$want" ] && continue
    echo "$p: $have -> $want"
    files="$files $apkfile"; names="$names $p"; pins="$pins $p=$have"
done
[ -n "$files" ] || { echo "already the bundled build"; exit 1; }

# 2. a way back
rm -rf "$ROLLBACK" && mkdir -p "$ROLLBACK" && cp /etc/apk/world "$ROLLBACK/world" || exit 11
restore_world() { cp "$ROLLBACK/world" /etc/apk/world; }
for pin in $pins; do
    # apk fetch takes no version constraint: fetch the repository's build and
    # require it to be exactly the installed one.
    p=${pin%%=*}; have=${pin#*=}
    apk fetch -q -o "$ROLLBACK" "$p" > /dev/null 2>&1
    if [ ! -f "$ROLLBACK/$p-$have.apk" ]; then
        echo "cannot download $p $have for a rollback (offline, or the repository has another build); nothing was changed"
        rm -rf "$ROLLBACK"; exit 11
    fi
done

# 3. dry run
sim=$(apk add --simulate --no-network $files 2>&1); rc=$?
echo "$sim"
bad=$(echo "$sim" | grep -E '^\([0-9]+/[0-9]+\) ' | while read -r _ verb name _; do
    case "$verb" in Downgrading|Upgrading|Replacing) ;; *) echo "$verb $name"; continue ;; esac
    case " $names " in *" $name "*) ;; *) echo "$verb $name" ;; esac
done)
if [ $rc -ne 0 ] || [ -n "$bad" ]; then
    echo "simulation refused:${bad:+ $bad}"; echo "nothing was changed"
    rm -rf "$ROLLBACK"; exit 12
fi

# 4. the real thing
if apk add --no-network $files && healthy; then
    restore_world; rm -rf "$ROLLBACK"; echo "restored"; exit 0
fi

# 5. roll back
echo "install failed, rolling back"
if apk add --no-network "$ROLLBACK"/*.apk && healthy; then
    restore_world; rm -rf "$ROLLBACK"; echo "rolled back to the previous build"; exit 13
fi
echo "rollback failed; the rollback packages are kept in $ROLLBACK"
exit 14

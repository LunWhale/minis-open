#!/bin/bash
# [T-aojit-sync] Record the AOJIT images Minis owns: the ones recorded HERE, not
# taken from ish-arm64's image sets, because they must match the app's bundled
# rootfs exactly.
#
#   libcrypto 3.3.2-r4, libssl 3.3.2-r4   tls_train.sh  on rootfs A + python3 py3-requests
#   pcre2 10.43-r0                        workloads/pcre_train.sh on rootfs A + git ripgrep
#
# Usage: deps/aot/tools/record_local.sh [libcrypto libssl pcre2]   (default: all three)
#   WORK=<dir>        scratch (default $TMPDIR/minis-aot-rec), ~1.5 GB
#   OUT=<dir>         where the .S go (default deps/aot)
#
# Gates (each one stops the run - a silent partial recording is how the
# abi 1f3bb5a0 copies from ish-arm64 lost 80% of libssl's coverage):
#   * the recorder's abi equals what deps/ish builds for the app;
#   * the rootfs keeps libcrypto3 / libssl3 3.3.2-r4 after `apk add`
#     (never install the openssl CLI in the guest: it upgrades libcrypto3;
#     the localhost certificates are made on the host instead);
#   * a dry run of each workload prints its ok markers and no FAIL;
#   * each recording has at least MIN translations (about 80% of the
#     2026-10-05 recording at abi 1f3bb5a0).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
ISH="$REPO/deps/ish"
WORK="${WORK:-${TMPDIR:-/tmp}/minis-aot-rec}"
OUT="${OUT:-$REPO/deps/aot}"
NET="$ISH/benchmark/aojit/guest/net"
MODULES=("${@:-libcrypto libssl pcre2}"); MODULES=(${MODULES[@]})

fail() { echo "❌ $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

# Per-module settings (macOS /bin/bash is 3.2: no associative arrays).
#   file | record substring | translation floor | guest workload | ok markers
spec() {
    case "$1" in
        libcrypto) echo "aot_libcrypto_3.3.2-r4.S|libcrypto.so|15000|/tmp/aojit/net/tls_train.sh|agent-cold-ok tls-train-ok" ;;
        libssl)    echo "aot_libssl_3.3.2-r4.S|libssl.so|5800|/tmp/aojit/net/tls_train.sh|agent-cold-ok tls-train-ok" ;;
        pcre2)     echo "aot_pcre2_10.43-r0.S|libpcre2-8.so|4100|/tmp/aojit/minis/pcre_train.sh|pcre-train-ok" ;;
        *) return 1 ;;
    esac
}
field() { spec "$1" | cut -d'|' -f"$2"; }

mkdir -p "$WORK"
REC="$WORK/ish-rec"; ROOT="$WORK/rec-A/alpine-rootfs"; I="$REC/ish"

step "🔧 recorder: CLI ish from deps/ish $(git -C "$ISH" rev-parse --short HEAD)"
[ -d "$REC" ] || meson setup "$REC" "$ISH" -Dguest_arch=arm64 -Dengine=asbestos -Dkernel=ish -Djit=true \
    -Db_ndebug=true --buildtype=release > "$WORK/meson.log"
ninja -C "$REC" > "$WORK/ninja.log" 2>&1 || ninja -C "$REC" >> "$WORK/ninja.log" 2>&1 || fail "recorder build ($WORK/ninja.log)"

step "📦 rootfs A (deps/resources/alpine-rootfs.zip) + training packages"
rm -rf "$WORK/rec-A"; mkdir -p "$WORK/rec-A"
unzip -q "$REPO/deps/resources/alpine-rootfs.zip" -d "$WORK/rec-A"
# Run in the guest; drop ish's NETDIAG noise. grep exits 1 on empty output: not an error here.
g() { "$I" -f "$ROOT" /bin/sh -c "$1" 2>&1 | { grep -v '^NETDIAG' || true; }; }
ABI_REC=$(ISH_JIT_PIC=1 "$I" -f "$ROOT" /bin/sh -c 'grep -o "abi [0-9a-f]*" /proc/ish/jit' 2>/dev/null | awk '{print $2}')
ABI_IMG=$(python3 "$REPO/deps/aot/tools/image_info.py" --json "$OUT" 2>/dev/null | python3 -c 'import json,sys; s={i["abi"] for i in json.load(sys.stdin)}; print(" ".join(sorted(x for x in s if x)))' || true)
echo "recorder abi $ABI_REC; images in $OUT: ${ABI_IMG:-none}"
[ -n "$ABI_REC" ] || fail "could not read the recorder's abi"
g 'echo nameserver 223.5.5.5 > /etc/resolv.conf; apk update >/dev/null 2>&1; apk add python3 py3-requests git ripgrep >/dev/null 2>&1; true'
V=$(g 'apk info -v 2>/dev/null | grep -E "^(libcrypto3|libssl3|py3-requests|pcre2)-[0-9]" | sort | tr "\n" " "')
echo "guest: $V"
echo "$V" | grep -q "libcrypto3-3.3.2-r4" && echo "$V" | grep -q "libssl3-3.3.2-r4" || fail "rootfs A no longer has OpenSSL 3.3.2-r4: $V"
echo "$V" | grep -q "py3-requests-" || fail "py3-requests missing: agent_cold.sh would FAIL and the TLS images would lose the verification path"

step "📂 workloads and host-made certificates"
S="$WORK/stage"; rm -rf "$S"; mkdir -p "$S/net" "$S/minis"
cp "$NET"/* "$S/net/"
cp "$REPO"/deps/aot/workloads/* "$S/minis/"
( cd "$S/net"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout rsa.key -out rsa.crt -days 365 -subj /CN=localhost \
      -addext subjectAltName=DNS:localhost,IP:127.0.0.1 2>/dev/null
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout ec.key -out ec.crt -days 365 \
      -subj /CN=localhost -addext subjectAltName=DNS:localhost,IP:127.0.0.1 2>/dev/null )
( cd "$S" && tar cf "$WORK/stage.tar" net minis )
"$I" -f "$ROOT" /bin/sh -c 'rm -rf /tmp/aojit /tmp/x; mkdir -p /tmp/aojit /tmp/x && tar xf - -C /tmp/x &&
    mv /tmp/x/net /tmp/aojit/net && mv /tmp/x/minis /tmp/aojit/minis && chown -R root:root /tmp/aojit &&
    cd /tmp/aojit/net && cat /etc/ssl/certs/ca-certificates.crt rsa.crt ec.crt > ca_bundle.pem' < "$WORK/stage.tar" 2>&1 | { grep -v '^NETDIAG' || true; }

for m in "${MODULES[@]}"; do
    spec "$m" >/dev/null || fail "unknown module $m (libcrypto libssl pcre2)"
    F_=$(field "$m" 1); M_=$(field "$m" 2); MIN_=$(field "$m" 3); WL_=$(field "$m" 4); OK_=$(field "$m" 5)
    step "🧪 dry run for $m: $WL_"
    "$I" -f "$ROOT" /bin/sh "$WL_" 2>&1 | { grep -v "^NETDIAG" || true; } > "$WORK/dry_$m.log" || true
    grep -q FAIL "$WORK/dry_$m.log" && fail "dry run printed FAIL ($WORK/dry_$m.log)"
    for k in $OK_; do grep -q "$k" "$WORK/dry_$m.log" || fail "dry run missing '$k' ($WORK/dry_$m.log)"; done

    step "📼 recording $m ($M_)"
    rec="$WORK/$m.jsonl"; rm -f "$rec"
    ISH_JIT_PIC=1 ISH_JIT_RECORD="$rec" ISH_JIT_RECORD_MOD="$M_" \
        "$I" -f "$ROOT" /bin/sh "$WL_" 2>&1 | { grep -v "^NETDIAG" || true; } > "$WORK/rec_$m.log" || true
    grep -q FAIL "$WORK/rec_$m.log" && fail "recording run printed FAIL ($WORK/rec_$m.log)"
    n=$(wc -l < "$rec" | tr -d ' ')
    [ "$n" -ge "$MIN_" ] || fail "$m: only $n translations (floor $MIN_) - the workload did not run fully"
    name=$(basename "$F_" .S | sed 's/^aot_//' | tr '.-' '__')
    python3 "$ISH/tools/jit_aot/gen.py" "$rec" "$I" "$ROOT/data" "$WORK/$F_" --name "$name" 2>&1 | grep '✅' || fail "gen.py $m"
    cp "$WORK/$F_" "$OUT/$F_"
    echo "✅ $m: $n translations -> $OUT/$F_"
done

step "📋 result"
imgs=(); for m in "${MODULES[@]}"; do imgs+=("$OUT/$(field "$m" 1)"); done
python3 "$REPO/deps/aot/tools/image_info.py" "${imgs[@]}"
echo "Next: deps/build_aot.sh, then AOJITTests."

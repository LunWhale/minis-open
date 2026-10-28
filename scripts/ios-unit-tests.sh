#!/bin/bash
# [T-ios-unit-test-infra] Run the iOS unit tests on this Mac without the real app.
#
#   scripts/ios-unit-tests.sh                       all MinisTests XCTests
#   scripts/ios-unit-tests.sh --only ImageRealIosAXCTests [--only Class/testMethod ...]
#   scripts/ios-unit-tests.sh --standalone 'ImageCtxIosE*' [--standalone 'ImageRealIos*']
#   scripts/ios-unit-tests.sh --no-xctest --standalone 'Foo*'   Standalone scripts only
#   scripts/ios-unit-tests.sh --skip-build          reuse the last build
#
# How it stays away from real data:
#   * MinisTests runs inside MinisTestHost (com.openminis.MinisTestHost): its own
#     container, signed with no entitlements (no App Group, no iCloud, no keychain
#     group). Minis.app is built (for Minis.debug.dylib, which the test bundle
#     links) but never installed, launched or listed as a test product.
#   * Before running, the build is checked: test host bundle id, its signed
#     entitlements, and that the .xctestrun names nothing from com.openminis.app.
#     Any mismatch stops the script before anything runs.
#   * static_check.py rejects tests that reach real storage (ChatStore.shared,
#     UserDefaults.standard, Documents, App Group, keychain, CloudKit).
#   * data_guard.py snapshots the real data before and after the run, and audits
#     containermanagerd's log for the run window; any finding fails the run.
#   * No -allowProvisioningUpdates: signing uses the profiles already on this Mac
#     and never registers anything with the developer account.
#
# Never use `xcodebuild test -scheme Minis` on a Mac "Designed for iPad"
# destination: its MinisUITests target launches the real app.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PROJ="$REPO/src/ios/Minis.xcodeproj"
DD="${MINIS_UNITTEST_DERIVED_DATA:-$REPO/build/DerivedData-unittests}"
TOOLS="$REPO/scripts/ios-unit-tests"
HOST_ID="com.openminis.MinisTestHost"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT="$DD/runs/$RUN_ID"
mkdir -p "$OUT"

ONLY=(); STANDALONE=(); SKIP_BUILD=0; XCTEST=1
while [ $# -gt 0 ]; do
  case "$1" in
    --only) ONLY+=("-only-testing:MinisTests/$2"); shift 2 ;;
    --standalone) STANDALONE+=("$2"); shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --no-xctest) XCTEST=0; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

t_start=$(date +%s)
step() { echo; echo "==> $*"; }
fail() { echo "FAILED: $*" >&2; exit 1; }

step "static check (tests must not reach real storage)"
python3 "$TOOLS/static_check.py" || fail "static check - fix the test, or justify it in $TOOLS/static-check-allowlist.tsv"

if [ "$XCTEST" = 1 ]; then
  MAC_ID=$(xcodebuild -project "$PROJ" -scheme MinisUnitTests -showdestinations 2>/dev/null \
           | sed -n 's/.*platform:macOS, arch:arm64, variant:Designed for \[iPad,iPhone\], id:\([^,]*\),.*/\1/p' | head -1)
  [ -n "$MAC_ID" ] || fail "no 'My Mac (Designed for iPad)' destination for MinisUnitTests"

  if [ "$SKIP_BUILD" = 0 ]; then
    step "build Minis (Debug) for Minis.debug.dylib - build only, never run"
    xcodebuild build -project "$PROJ" -scheme Minis -configuration Debug -destination 'generic/platform=iOS' \
      -derivedDataPath "$DD" > "$OUT/build-app.log" 2>&1 || { tail -30 "$OUT/build-app.log"; fail "app build ($OUT/build-app.log)"; }
    step "build MinisTestHost + MinisTests"
    rm -f "$DD"/Build/Products/*.xctestrun
    xcodebuild build-for-testing -project "$PROJ" -scheme MinisUnitTests -configuration Debug \
      -destination "id=$MAC_ID" -derivedDataPath "$DD" > "$OUT/build-tests.log" 2>&1 \
      || { grep -E "error:" "$OUT/build-tests.log" | sort -u | head -30; fail "test build ($OUT/build-tests.log)"; }
  fi

  step "check the test host before running anything"
  XCTESTRUN=$(ls "$DD"/Build/Products/MinisUnitTests_*.xctestrun 2>/dev/null | head -1)
  [ -n "$XCTESTRUN" ] || fail "no .xctestrun - build first"
  HOST_APP="$DD/Build/Products/Debug-iphoneos/MinisTestHost.app"
  [ "$(plutil -extract CFBundleIdentifier raw "$HOST_APP/Info.plist")" = "$HOST_ID" ] || fail "test host bundle id is not $HOST_ID"
  plutil -p "$XCTESTRUN" | grep -q "\"TestHostBundleIdentifier\" => \"$HOST_ID\"" || fail ".xctestrun test host is not $HOST_ID"
  if plutil -p "$XCTESTRUN" | grep -qE 'com\.openminis\.app|/Minis\.app'; then fail ".xctestrun names the real app"; fi
  ENT=$(codesign -d --entitlements :- "$HOST_APP" 2>/dev/null | plutil -convert json -o - - 2>/dev/null || echo '{}')
  KEYS=$(python3 -c 'import json,sys; print(" ".join(sorted(json.loads(sys.argv[1]).keys())))' "$ENT")
  [ "$KEYS" = "application-identifier com.apple.developer.team-identifier get-task-allow" ] \
    || fail "test host entitlements must be exactly application-identifier/team-identifier/get-task-allow, got: $KEYS"
  echo "test host $HOST_ID, entitlements: $KEYS; .xctestrun has no com.openminis.app product"

fi

# Everything below runs test code. The real data is snapshotted before and
# compared after, around the XCTest run AND the Standalone scripts (those run as
# plain macOS processes, so they get the same guard).
step "snapshot real data (before)"
python3 "$TOOLS/data_guard.py" snapshot "$OUT/before.json"
T0=$(date '+%Y-%m-%d %H:%M:%S')
TEST_RC=0

if [ "$XCTEST" = 1 ]; then
  step "run MinisTests in MinisTestHost"
  set +e
  # The scheme form (not -xctestrun) is what installs the iOS-on-Mac wrapper
  # (.XCInstall/MinisTestHost.app); the products it uses are the ones checked above.
  xcodebuild test-without-building -project "$PROJ" -scheme MinisUnitTests -configuration Debug \
    -destination "id=$MAC_ID" -derivedDataPath "$DD" \
    -resultBundlePath "$OUT/result.xcresult" ${ONLY[@]+"${ONLY[@]}"} > "$OUT/test.log" 2>&1
  TEST_RC=$?
  set -e
  grep -E "Test Case .* (passed|failed|skipped)" "$OUT/test.log" | sed -E 's/^.*Test Case .-\[MinisTests\.([^ ]+) ([^]]+)\]. /\1.\2 /' > "$OUT/cases.txt" || true
fi

SA_RC=0
if [ ${#STANDALONE[@]} -gt 0 ]; then
  step "Standalone scripts"
  cd "$REPO/src/ios/MinisTests/Standalone"
  for pat in "${STANDALONE[@]}"; do
    for f in $pat.swift; do
      [ -f "$f" ] || continue
      s=$(date +%s)
      log="$OUT/standalone-${f%.swift}.log"
      if timeout 600 swift "$f" > "$log" 2>&1 && ! grep -q "❌" "$log"; then r=PASS; else r=FAIL; SA_RC=1; fi
      echo "  $r  $f  ($(( $(date +%s) - s ))s, ✅ $(grep -c '✅' "$log" || true) / ❌ $(grep -c '❌' "$log" || true))"
    done
  done
  cd "$REPO"
fi

sleep 2
T1=$(date '+%Y-%m-%d %H:%M:%S')
step "snapshot real data (after) + containermanagerd audit"
python3 "$TOOLS/data_guard.py" snapshot "$OUT/after.json"
set +e
python3 "$TOOLS/data_guard.py" diff "$OUT/before.json" "$OUT/after.json" "$T0" "$T1" | tee "$OUT/data-guard.txt"
GUARD_RC=${PIPESTATUS[0]}
set -e

if [ "$XCTEST" = 1 ]; then
  step "XCTest results"
  PASSED=$(grep -c " passed " "$OUT/cases.txt" || true); FAILED=$(grep -c " failed " "$OUT/cases.txt" || true)
  SKIPPED=$(grep -c " skipped " "$OUT/cases.txt" || true)
  GAPS=$(grep -c "KNOWN GAP" "$OUT/test.log" || true)
  grep " failed " "$OUT/cases.txt" | head -40 || true
  grep -E "Executed [0-9]+ tests?" "$OUT/test.log" | tail -1 || true
  echo "XCTest: $PASSED passed, $FAILED failed, $SKIPPED skipped, KNOWN GAP lines: $GAPS (log: $OUT/test.log)"
fi

echo
echo "total $(( $(date +%s) - t_start ))s, logs in $OUT"
[ "$GUARD_RC" = 0 ] || fail "data guard - see $OUT/data-guard.txt"
[ "$TEST_RC" = 0 ] || exit 1
exit $SA_RC

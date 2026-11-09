#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Build Airc.app on the build Mac.
#
#   scripts/build-app.sh                 test AircKit, build build/Airc.app (release, ad-hoc signed); fails first if
#                                        Info.plist lacks a privacy usage description (PRIVACY_KEYS below)
#   scripts/build-app.sh --debug         debug build
#   scripts/build-app.sh --no-test       skip the AircKit tests
#   scripts/build-app.sh --snapshots DIR after building, run the scripted snapshot scenarios into DIR
#                                        (showcase, onboarding on a synthetic import, relaunch check, and the
#                                        real-event checks; fails if any check logs FAIL, or a scenario writes no
#                                        log because the app crashed). With the Chromium engine built in, the same
#                                        scenarios run on it too, into DIR/chromium, plus its dialog checks.
#   scripts/build-app.sh --engine webkit only the WebKit dev engine, even if the Chromium framework exists
#   scripts/build-app.sh --snapshot-engines webkit|chromium|webkit,chromium   which engines the snapshots run on
#   SPARKLE_ROOT=<dir> scripts/build-app.sh   release wiring: link and embed <dir>/Sparkle.framework (the pinned
#                                        official distribution, scripts/release/setup-sparkle.sh), add "Check for
#                                        Updates…", the feed (AIRC_UPDATE_FEED) and the public key, sign with
#                                        scripts/release/sign.py. Automatic checks stay off until the feed is live.
#   AIRC_DEV_CHANNEL=1 AIRC_UPDATE_FEED=https://… scripts/build-app.sh   the private dev channel (docs/release.md):
#                                        Sparkle from ~/arcfork/tools/sparkle; Airc-Chromium.app checks at launch and
#                                        hourly, downloads by itself and offers "Restart to update"
#   AIRC_SOURCE_REV=<commit>             the AircRevision of a copy without .git
#   AIRC_SIGN_IDENTITY=<identity>        sign with this certificate instead of ad hoc (the owner's dev builds: an
#                                        Apple-issued one keeps Keychain's "Always Allow" across updates, docs/release.md)
#   AIRC_BUNDLE_ID=… AIRC_LAUNCH_ARGS='…'   a test install's own identity and default options (update proofs)
#   AIRC_PUBLIC_BUILD=1                  a public build (scripts/release/package.sh): compiled without AIRC_TESTING, so
#                                        no scripted scenarios, test options or test hooks (App/TestingGate.swift); refuses
#                                        --snapshots, AIRC_LAUNCH_ARGS and AIRC_BUNDLE_ID. Every other build is a dev/test
#                                        build with -D AIRC_TESTING. The two keep separate SwiftPM build folders.
#
# The app is a SwiftPM executable (apps/browser) wrapped into a bundle here; no Xcode project needed.
# Chromium: when `Airc Framework.framework` exists at $CHROMIUM_OUT (default ~/arcfork/chromium/src/out/AircRelease, else out/Airc), a second
# bundle, build/Airc-Chromium.app, links and embeds it and runs on Chromium (scripts/perf.sh --app
# build/Airc-Chromium.app). build/Airc.app is always the fast WebKit build. Without the framework: WebKit only, said so.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG=release
TEST=1
SNAPSHOTS=""
ENGINE=auto
SNAPSHOT_ENGINES=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) CONFIG=debug ;;
    --no-test) TEST=0 ;;
    --snapshots) SNAPSHOTS="$2"; shift ;;
    --engine) ENGINE="$2"; shift ;;
    --snapshot-engines) SNAPSHOT_ENGINES="$2"; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

# The release engine (out/AircRelease) is the current one: the ship loop, nightly and owner builds link it. out/Airc
# (DCHECK) is only rebuilt on request (its objects were removed for disk), so it is used only when asked for or alone.
if [[ -z ${CHROMIUM_OUT:-} ]]; then
  CHROMIUM_OUT="$HOME/arcfork/chromium/src/out/AircRelease"
  [[ -d "$CHROMIUM_OUT/Airc Framework.framework" ]] || CHROMIUM_OUT="$HOME/arcfork/chromium/src/out/Airc"
fi
FRAMEWORK="$CHROMIUM_OUT/Airc Framework.framework"
WITH_CHROMIUM=0
if [[ "$ENGINE" != webkit ]]; then
  if [[ -f "$FRAMEWORK/Airc Framework" ]]; then
    WITH_CHROMIUM=1
  else
    echo "== Chromium: no framework at $FRAMEWORK; building the WebKit engine only (Chromium skipped)"
  fi
fi
[[ -n "$SNAPSHOT_ENGINES" ]] || { SNAPSHOT_ENGINES=webkit; [[ $WITH_CHROMIUM == 1 ]] && SNAPSHOT_ENGINES=webkit,chromium; }

# Test code is compiled in unless this is a public build (App/TestingGate.swift). Public builds use their own SwiftPM
# folders, so switching between the two never invalidates the other's cache.
PUBLIC=${AIRC_PUBLIC_BUILD:-0}
if [[ $PUBLIC == 1 ]]; then
  [[ -z "$SNAPSHOTS" ]] || { echo "error: a public build has no scripted scenarios (--snapshots)" >&2; exit 2; }
  [[ -z "${AIRC_LAUNCH_ARGS:-}${AIRC_BUNDLE_ID:-}" ]] || { echo "error: AIRC_LAUNCH_ARGS and AIRC_BUNDLE_ID are for test installs" >&2; exit 2; }
  TESTING_FLAGS=()
  WEBKIT_SCRATCH=(--scratch-path "$ROOT/build/.swiftpm-public")
  CHROMIUM_SCRATCH="$ROOT/build/.swiftpm-chromium-public"
  echo "== public build: no test code (AIRC_TESTING unset)"
else
  TESTING_FLAGS=(-Xswiftc -DAIRC_TESTING)
  WEBKIT_SCRATCH=()
  CHROMIUM_SCRATCH="$ROOT/build/.swiftpm-chromium"
fi

# Privacy usage descriptions (the keys Chrome sets). Without one, macOS kills the app (TCC, SIGABRT) the first time a
# page or Google sign-in touches that resource: Google sign-in looks for phone passkeys over Bluetooth. Checked in the
# source plist before building and again in every bundle.
PRIVACY_KEYS=(NSBluetoothAlwaysUsageDescription NSBluetoothPeripheralUsageDescription NSCalendarsFullAccessUsageDescription NSCameraUsageDescription
  NSMicrophoneUsageDescription NSAudioCaptureUsageDescription NSLocationUsageDescription
  NSLocationWhenInUseUsageDescription NSLocalNetworkUsageDescription NSWebBrowserPublicKeyCredentialUsageDescription)
check_privacy_keys() {   # check_privacy_keys PLIST
  local missing=() key value
  for key in "${PRIVACY_KEYS[@]}"; do
    value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$1" 2>/dev/null || true)"
    [[ -n "${value//[[:space:]]/}" ]] || missing+=("$key")
  done
  value="$(/usr/libexec/PlistBuddy -c "Print :NSBonjourServices" "$1" 2>/dev/null || true)"
  [[ "$value" == *"_googlecast._tcp"* ]] || missing+=("NSBonjourServices:_googlecast._tcp")
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "error: $1 has no usage description for: ${missing[*]}" >&2
    echo "  macOS kills the app the first time a page or sign-in uses one of these (TCC privacy violation)." >&2
    exit 1
  fi
}
check_privacy_keys "$ROOT/apps/browser/Resources/Info.plist"

if [[ $TEST == 1 ]]; then
  echo "== AircKit tests"
  if ! swift test --package-path "$ROOT/packages/AircKit" 2>&1 | python3 "$ROOT/infra/xctest_summary.py"; then
    echo "AircKit tests failed" >&2; exit 1
  fi
fi

# Two bundles. build/Airc.app is the WebKit dev engine only: linking Chromium's framework makes every launch load it
# (3–7 s on the build Mac, even for WebKit runs; 0.2 s without). build/Airc-Chromium.app links and embeds the framework
# and defaults to Chromium (AircDefaultEngine); it builds in its own SwiftPM scratch folder so neither invalidates the
# other's cache.
# The source commit (AircRevision). A copy without .git (the nightly's export, scripts/mac.sh) passes AIRC_SOURCE_REV.
GIT_REV="${AIRC_SOURCE_REV:-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo dev)}"

# Private dev channel (docs/release.md): AIRC_DEV_CHANNEL=1 and the operator's HTTPS feed (AIRC_UPDATE_FEED, from local
# config, never committed). Embeds Sparkle; the Chromium bundle checks at launch and hourly and downloads by itself.
if [[ ${AIRC_DEV_CHANNEL:-0} == 1 ]]; then
  export AIRC_UPDATE_FEED=${AIRC_UPDATE_FEED:-http://127.0.0.1:3483/appcast.xml}
  [[ "$AIRC_UPDATE_FEED" == https://* || "$AIRC_UPDATE_FEED" == http://127.0.0.1:3483/appcast.xml ]] || { echo "AIRC_UPDATE_FEED must be HTTPS or the local dev feed" >&2; exit 2; }
  export SPARKLE_ROOT=${SPARKLE_ROOT:-$HOME/arcfork/tools/sparkle}
  [[ -d "$SPARKLE_ROOT/Sparkle.framework" ]] || { echo 'Run scripts/release/setup-sparkle.sh first' >&2; exit 1; }
  export AIRC_UPDATE_CHANNEL=dev
fi
# Product analytics (docs/user/telemetry.md): PostHog's host and project key from infra/release/telemetry.json (the key
# is public and write-only). AIRC_TELEMETRY_HOST / AIRC_TELEMETRY_KEY override them, e.g. a delivery check's loopback
# mock; an empty key builds an app with telemetry off.
TELEMETRY_HOST="${AIRC_TELEMETRY_HOST-$(plutil -extract host raw -o - "$ROOT/infra/release/telemetry.json" 2>/dev/null || true)}"
TELEMETRY_KEY="${AIRC_TELEMETRY_KEY-$(plutil -extract key raw -o - "$ROOT/infra/release/telemetry.json" 2>/dev/null || true)}"

# Crash symbols (docs/user/telemetry.md, "Crash reports"): release builds that get published (the dev channel, public
# builds) keep dSYMs of the executable (made before it is stripped), the Chromium framework and Sparkle in build/dSYMs,
# beside the bundles and never inside them or the DMG; infra/updates/upload-symbols.sh sends them to PostHog.
# AIRC_DSYMS=1 or 0 overrides.
DSYMS=${AIRC_DSYMS:-0}
[[ -n ${AIRC_DSYMS:-} || ( ${AIRC_DEV_CHANNEL:-0} != 1 && $PUBLIC != 1 ) ]] || DSYMS=1
[[ $CONFIG == release ]] || DSYMS=0
DSYM_DIR="$ROOT/build/dSYMs"
dsym() {   # dsym BINARY NAME: BINARY's dSYM as build/dSYMs/NAME
  mkdir -p "$DSYM_DIR"
  rm -rf "${DSYM_DIR:?}/$2"
  # swift_build's prefix maps, undone so dsymutil finds the module caches (all but SwiftShims', whose type info
  # symbolication doesn't need). Chromium's framework has no DWARF (symbol_level = 0): its dSYM carries the symbol
  # table only.
  xcrun dsymutil "$1" -o "$DSYM_DIR/$2" "--object-prefix-map=/airc=$ROOT" "--object-prefix-map=/build-home=$HOME" 2>&1 \
    | grep -vE 'no debug symbols in executable|SwiftShims-[A-Z0-9]+\.pcm' || true
  xcrun dwarfdump --uuid "$DSYM_DIR/$2" 2>/dev/null | sed "s|$DSYM_DIR/||; s/^/  dSYM /" || echo "  dSYM $2: not made" >&2
}

# Sparkle (docs/release.md): only when SPARKLE_ROOT names the pinned official distribution.
SPARKLE_FLAGS=()
if [[ -n "${SPARKLE_ROOT:-}" ]]; then
  SPARKLE_FLAGS=(-Xswiftc -F -Xswiftc "$SPARKLE_ROOT" -Xlinker "-F$SPARKLE_ROOT"
    -Xlinker -framework -Xlinker Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
fi

bundle() {   # bundle APP BIN [chromium]
  local app=$1 bin=$2 chromium=${3:-}
  echo "== bundle $app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$bin" "$app/Contents/MacOS/Airc"
  [[ $DSYMS != 1 ]] || dsym "$bin" "$(basename "$app").dSYM"
  # ld's N_OSO debug records retain absolute object/module paths even with prefix maps.
  [[ "$CONFIG" != release ]] || xcrun strip -S "$app/Contents/MacOS/Airc"
  "$ROOT/scripts/release/copy-licenses.sh" "$app" "$CHROMIUM_OUT"
  python3 "$ROOT/scripts/bundle-blocking-lists.py" "$app"
  cp "$ROOT/apps/browser/Resources/Info.plist" "$app/Contents/Info.plist"
  # The app icon (assets/brand/README.md): Info.plist names it with CFBundleIconFile = AppIcon.
  cp "$ROOT/assets/brand/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
  # Settings › Appearance › App Icon's Outline (Settings/AppPersonalization.swift puts it on the icon grid).
  cp "$ROOT/assets/brand/airc-outline-squircle.png" "$app/Contents/Resources/AppIconOutline.png"
  # The public suffix list for Boosts' sites (AircKit/PublicSuffixList.swift; packages/AircKit/Resources, MPL-2.0),
  # deflated: the bundle scan flags ".ts.net", and the list has Tailscale's public suffix (Chromium compiles it too).
  python3 - "$ROOT/packages/AircKit/Resources/public_suffix_list.dat" "$app/Contents/Resources/public_suffix_list.dat.deflate" <<'PY'
import sys, zlib
c = zlib.compressobj(9, zlib.DEFLATED, -15)
open(sys.argv[2], 'wb').write(c.compress(open(sys.argv[1], 'rb').read()) + c.flush())
PY
  /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$app/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" "$app/Contents/Info.plist"
  # K07: Arc's AppleScript dictionary (apps/browser/Resources/Airc.sdef, docs/user/scripting.md).
  cp "$ROOT/apps/browser/Resources/Airc.sdef" "$app/Contents/Resources/Airc.sdef"
  /usr/libexec/PlistBuddy -c "Add :NSAppleScriptEnabled bool true" -c "Add :OSAScriptingDefinition string Airc.sdef" \
    "$app/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :AircRevision string $GIT_REV" "$app/Contents/Info.plist" 2>/dev/null || true
  [[ -z "$TELEMETRY_KEY" ]] || /usr/libexec/PlistBuddy -c "Add :AircTelemetryHost string $TELEMETRY_HOST" \
    -c "Add :AircTelemetryKey string $TELEMETRY_KEY" "$app/Contents/Info.plist"
  # A test install (an update proof in a throwaway folder) keeps its options across Sparkle's relaunch, which drops the
  # command line: AIRC_LAUNCH_ARGS become the bundle's default options, under its own AIRC_BUNDLE_ID. Never published to
  # the dev feed (infra/updates/publish.py refuses it).
  if [[ -n "${AIRC_BUNDLE_ID:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $AIRC_BUNDLE_ID" "$app/Contents/Info.plist"
  elif [[ ${AIRC_PUBLIC_BUILD:-0} != 1 ]]; then
    # Dev and test builds carry their own identity, so Launch Services never hands the owner's links (or TCC grants)
    # to a test copy: on 2026-11-06 links from other apps went to a deleted test build and opened nothing.
    # infra/updates/prepare-mac.sh puts the published identity back on the staged copy before signing it.
    local published test_id=org.airc.Airc.test
    [[ -n "$chromium" ]] || test_id=org.airc.Airc.test.webkit
    published=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app/Contents/Info.plist")
    /usr/libexec/PlistBuddy -c "Add :AircPublishedBundleID string $published" \
      -c "Set :CFBundleIdentifier $test_id" "$app/Contents/Info.plist"
  fi
  if [[ -n "${AIRC_LAUNCH_ARGS:-}" ]]; then
    local i=0 arg
    /usr/libexec/PlistBuddy -c "Add :AircLaunchArguments array" "$app/Contents/Info.plist"
    for arg in $AIRC_LAUNCH_ARGS; do
      /usr/libexec/PlistBuddy -c "Add :AircLaunchArguments:$i string $arg" "$app/Contents/Info.plist"
      i=$((i + 1))
    done
  fi
  if [[ -n "$chromium" ]]; then
    /usr/libexec/PlistBuddy -c "Add :AircDefaultEngine string chromium" "$app/Contents/Info.plist"
    "$ROOT/engine/embed-framework.sh" "$app" "$CHROMIUM_OUT" 2>&1 | sed '/replacing existing signature/d'
    [[ $DSYMS != 1 ]] || dsym "$FRAMEWORK/Airc Framework" "Airc Framework.framework.dSYM"
  fi
  check_privacy_keys "$app/Contents/Info.plist"
  if [[ -n "${SPARKLE_ROOT:-}" ]]; then
    mkdir -p "$app/Contents/Frameworks"
    ditto "$SPARKLE_ROOT/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
    if [[ $DSYMS == 1 && -d "$SPARKLE_ROOT/Symbols/Sparkle.framework.dSYM" ]]; then
      mkdir -p "$DSYM_DIR" && ditto "$SPARKLE_ROOT/Symbols/Sparkle.framework.dSYM" "$DSYM_DIR/Sparkle.framework.dSYM"
    fi
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string ${AIRC_UPDATE_FEED:-https://aircbrowser.com/appcast.xml}" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $(cat "$ROOT/infra/release/sparkle-public-key.txt")" "$app/Contents/Info.plist"
    # The feed isn't live yet: no automatic checks (and no first-launch prompt asking about them).
    /usr/libexec/PlistBuddy -c 'Add :SUEnableAutomaticChecks bool false' "$app/Contents/Info.plist"
    # The dev feed carries Chromium builds: the WebKit bundle stays on stable, checking only when asked.
    local channel=${AIRC_UPDATE_CHANNEL:-stable}
    [[ $channel == dev && -z "$chromium" ]] && channel=stable
    /usr/libexec/PlistBuddy -c "Add :AircUpdateChannel string $channel" "$app/Contents/Info.plist"
    if [[ $channel == dev ]]; then
      /usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true' "$app/Contents/Info.plist"
      /usr/libexec/PlistBuddy -c 'Add :AircDevChannel bool true' "$app/Contents/Info.plist"
      /usr/libexec/PlistBuddy -c 'Set :SUEnableAutomaticChecks true' "$app/Contents/Info.plist"
      /usr/libexec/PlistBuddy -c 'Add :SUAutomaticallyUpdate bool true' "$app/Contents/Info.plist"
      /usr/libexec/PlistBuddy -c 'Add :SUScheduledCheckInterval integer 3600' "$app/Contents/Info.plist"
    fi
    python3 "$ROOT/scripts/release/sign.py" "$app" "${AIRC_SIGN_IDENTITY:--}"
  elif [[ -z "$chromium" ]]; then
    codesign --force --sign "${AIRC_SIGN_IDENTITY:--}" --timestamp=none "$app"
  fi
  codesign --verify "$app"
  if [[ -n ${AIRC_SIGN_IDENTITY:-} ]]; then echo "signed (AIRC_SIGN_IDENTITY)"; else echo "signed (ad hoc)"; fi
}

# swift build with its output cut to the last 40 lines; on failure, every error line too (the warnings push them out).
swift_build() {
  local log rc=0
  log="$(mktemp)"
  # Map diagnostic source locations as well as DWARF; neither belongs to the build host.
  swift build "$@" -Xswiftc -file-prefix-map -Xswiftc "$ROOT=/airc" \
    -Xswiftc -debug-prefix-map -Xswiftc "$HOME=/build-home" > "$log" 2>&1 || rc=$?
  grep -vE "^\[[0-9]+/[0-9]+\] (Compiling|Emitting)" "$log" | tail -40
  [[ $rc == 0 ]] || sed $'s/\x1b\\[[0-9;]*m//g' "$log" | grep -E "error:" | sort -u | head -40 >&2
  rm -f "$log"
  return $rc
}

echo "== blocking filter bridge (standalone WebKit)"
"$ROOT/engine/core/blocking-rust/build-standalone.sh" "$ROOT/build/blocking"
BLOCKING_MODULE=(-Xswiftc -I -Xswiftc "$ROOT/engine/core/blocking-rust/include")
BLOCKING_LINK=(-Xlinker "$ROOT/build/blocking/target/release/libairc_blocking.a" -Xlinker -lresolv -Xlinker -liconv)
echo "== swift build ($CONFIG, WebKit)"
swift_build --package-path "$ROOT/apps/browser" -c "$CONFIG" ${WEBKIT_SCRATCH[@]+"${WEBKIT_SCRATCH[@]}"} "${BLOCKING_MODULE[@]}" "${BLOCKING_LINK[@]}" \
  ${TESTING_FLAGS[@]+"${TESTING_FLAGS[@]}"} ${SPARKLE_FLAGS[@]+"${SPARKLE_FLAGS[@]}"} \
  || { echo "build failed" >&2; exit 1; }
APP="$ROOT/build/Airc.app"
bundle "$APP" "$(swift build --package-path "$ROOT/apps/browser" -c "$CONFIG" ${WEBKIT_SCRATCH[@]+"${WEBKIT_SCRATCH[@]}"} \
  ${SPARKLE_FLAGS[@]+"${SPARKLE_FLAGS[@]}"} --show-bin-path)/Airc"

CHROMIUM_APP="$ROOT/build/Airc-Chromium.app"
if [[ $WITH_CHROMIUM == 1 ]]; then
  echo "== swift build ($CONFIG, Chromium: linking $FRAMEWORK)"
  SCRATCH="$CHROMIUM_SCRATCH"
  # SwiftPM doesn't track engine/core/public (outside the package): when its headers change, the precompiled AircCore
  # module goes stale and the build fails with "has been modified since the module file … was built". Drop it then.
  STAMP="$SCRATCH/.engine-headers"
  if [[ ! -e "$STAMP" ]] || [[ -n "$(find "$ROOT/engine/core/public" -newer "$STAMP" -print -quit)" ]]; then
    rm -f "$SCRATCH"/out/Intermediates.noindex/SwiftExplicitPrecompiledModules/AircCore-*.pcm
  fi
  mkdir -p "$SCRATCH" && touch "$STAMP"
  ENGINE_FLAGS=(--scratch-path "$SCRATCH" "${BLOCKING_MODULE[@]}" -Xswiftc -I -Xswiftc "$ROOT/engine/core/public"
    -Xlinker "$FRAMEWORK/Airc Framework" -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
  swift_build --package-path "$ROOT/apps/browser" -c "$CONFIG" "${ENGINE_FLAGS[@]}" ${TESTING_FLAGS[@]+"${TESTING_FLAGS[@]}"} \
    ${SPARKLE_FLAGS[@]+"${SPARKLE_FLAGS[@]}"} || { echo "Chromium build failed" >&2; exit 1; }
  bundle "$CHROMIUM_APP" "$(swift build --package-path "$ROOT/apps/browser" -c "$CONFIG" --scratch-path "$SCRATCH" ${SPARKLE_FLAGS[@]+"${SPARKLE_FLAGS[@]}"} --show-bin-path)/Airc" chromium
  echo "== also $CHROMIUM_APP (Chromium engine; --engine=webkit still works)"
fi

# Both bundles now contain their own framework copies. Release the compile lock before UI checks;
# the coordinator's ship lock still prevents engine reconciliation during a qualifying ship run.
if [[ -n ${AIRC_BUILD_LOCK_FD:-} ]]; then
  python3 -c 'import fcntl, os; fcntl.flock(int(os.environ["AIRC_BUILD_LOCK_FD"]), fcntl.LOCK_UN)'
fi

if [[ -n "$SNAPSHOTS" ]]; then
  rm -rf "$SNAPSHOTS"; mkdir -p "$SNAPSHOTS"
  OUT_ROOT="$(cd "$SNAPSHOTS" && pwd)"
  # Keep the display awake while scenarios run (display-link animations stall once it sleeps), only for this run.
  caffeinate -d -w $$ &
  # Never publish an untested locked-screen build. Check after compilation, just before UI.
  UI_GATE="$OUT_ROOT/ui-gate.json"
  if [[ ${AIRC_SHIP_GATE:-0} == 1 ]]; then
    python3 "$ROOT/infra/ui_gate.py" preflight "$UI_GATE" || exit $?
  else
    # Non-ship runs still collect evidence and return ENV when drawing was blocked.
    python3 "$ROOT/infra/ui_gate.py" preflight "$UI_GATE" || true
  fi
  # Each engine runs the same scenarios. Everything a run writes (store, engine data, caches, defaults) stays in
  # build/snapshot-home/<engine>: CFFIXED_USER_HOME moves the app's home folder there, and Chromium's profiles live
  # in each run's --data-dir. -g: don't take focus on the owner's Mac. -W: wait until the app quits.
  # A shared Mac has one display and pasteboard. Lock each launch (including its shutdown), with a cumulative
  # five-minute wait budget for this entire run. Timeout runs still need per-case interference evidence.
  UI_LOCK_BUDGET="$ROOT/build/.ui-lock-budget-$$"
  echo 0 > "$UI_LOCK_BUDGET"
  trap 'rm -f "$UI_LOCK_BUDGET"' EXIT
  ui_open() { AIRC_UI_LOCK_BUDGET_FILE="$UI_LOCK_BUDGET" python3 "$ROOT/scripts/ui-check-lock.py" python3 "$ROOT/infra/ui_gate.py" launch "$UI_GATE" open "$@"; }
  scenarios() {
    local engine=$1 out=$2 home="$ROOT/build/snapshot-home/$1"
    echo "== snapshots ($engine) -> $out"
    rm -rf "$home"; mkdir -p "$home/Library" "$out"
    local app="$APP"; [[ $engine == chromium ]] && app="$CHROMIUM_APP"
    # A scenario writes its log section when it finishes; none means the app crashed or never started.
    launch() {
      ui_open -g -n -W --env "CFFIXED_USER_HOME=$home" --env "AIRC_SHIP_GATE=${AIRC_SHIP_GATE:-0}" "$app" --args --engine="$engine" --snapshot "$out" "$@"
      grep -qx "\[$2\]" "$out/log.txt" 2>/dev/null || echo "FAIL $2: the app wrote no log (crashed or never started)" >> "$out/log.txt"
    }
    for pass in write read; do launch --script profilesignin --data-dir "$home/ProfileSignIn"; done
    launch --script showcase --ephemeral --data-dir "$home/Airc"
    # First run (ON-1…5) on a synthetic Arc import fixture: never the owner's Arc data or Keychain.
    launch --script onboarding --onboarding --ephemeral --data-dir "$home/Onboarding"
    # Onboarding end to end on a real-size synthetic Arc (OnboardingE2ECheck.swift): the first run from Welcome into the
    # browser window, then Import from Arc… re-importing without duplicates and closing from every step. Google sign-in is
    # a loopback mock of ListAccounts and the default browser a stand-in: no real account, no system dialog.
    launch --script onboarding-e2e --onboarding --ephemeral --data-dir "$home/OnboardingE2E"
    # Other browsers (IM-4) on synthetic ones only (BrowserFixtures.swift: Chrome with its History locked, Brave, Firefox, a
    # Safari export, password CSV files): Airc → Import from Another Browser…, re-imports without duplicates, CSV passwords.
    launch --script arcimport2 --ephemeral --data-dir "$home/ArcImport2" "--host-resolver-rules=MAP chromewebstore.google.com 127.0.0.1" --disable-features=HttpsUpgrades
    launch --script import-browsers --ephemeral --data-dir "$home/ImportBrowsers"
    # P22 (E11): Arc import acceptance on synthetic Arcs (ImportAcceptanceCheck.swift): source permutations, the WAL
    # warning and reimport, profile mapping, the extension checklist's states, the Keychain's answers simulated, a
    # wrong key, a partial login result and Try Again. Never the owner's Arc profile or Keychain.
    launch --script arcaccept --ephemeral --data-dir "$home/ArcAccept"
    # Relaunch check: one run writes Spaces and tabs, a second run on the same data shows them.
    launch --script persist-write --data-dir "$home/Persist"
    launch --script persist-read --data-dir "$home/Persist"
    # SV-1: a split on screen at quit comes back as it was (panes, order, axis, sizes, focused pane).
    launch --script split-write --data-dir "$home/Split"
    launch --script split-read --data-dir "$home/Split"
    # Real clicks and keys through the window (EventTests.swift): a control that draws but doesn't respond fails.
    launch --script events --ephemeral --data-dir "$home/Events"
    launch --script routing --ephemeral --data-dir "$home/Routing" "--host-resolver-rules=MAP *.co.uk 127.0.0.1" --disable-features=HttpsUpgrades
    # Page, editor and field shortcuts on a loopback editor page, and Airc's own against Arc's (ShortcutsCheck.swift).
    launch --script shortcuts --ephemeral --data-dir "$home/Shortcuts"
    # Settings → Shortcuts (ShortcutRemapCheck.swift): ⌘L moved to ⌥⌘L (the page gets ⌘L, ⌥⌘L edits the URL), a swap,
    # refused and page keys, Delete, resets; the menus, settings.json, a private window and Little Arc follow each change.
    launch --script shortcutremap --ephemeral --data-dir "$home/ShortcutRemap"
    # Chromium's web-modal dialogs in our window (passkeys, HTTP auth, beforeunload), read through the engine's test
    # hook, which only answers on its scratch-data, mock-keychain test gate.
    if [[ $engine == chromium ]]; then
      mkdir -p "$home/Dialogs/Chromium"   # the gate compares real paths, so the folder must exist at launch
      launch --script dialogs --data-dir "$home/Dialogs" --airc-data-dir="$home/Dialogs" --airc-test=modalDialogs
      # SB-3: permission, password and address/card prompts drawn by the app, answered by real clicks (PromptScenario).
      # Fake camera and microphone: macOS's own camera prompt never shows, and nothing real is captured.
      launch --script prompts --data-dir "$home/Prompts" --use-fake-device-for-media-stream
      # Fullscreen exits: no captures/devices/HID; skip unless drawn and hardware idle >= 3 minutes.
      # Each attempt is capped below 60 seconds and launched into its own scratch profile.
      for fullscreen_case in native native-rapid native-video native-split html switch split little pip webkit-esc; do
        local fullscreen_out="$out/fullscreen-$fullscreen_case"
        mkdir -p "$fullscreen_out"
        rm -f "$fullscreen_out/log.txt"
        ui_open -g -n -W --env "CFFIXED_USER_HOME=$home" --env "AIRC_SHIP_GATE=${AIRC_SHIP_GATE:-0}" \
          --env "AIRC_FULLSCREEN_CASE=$fullscreen_case" "$app" --args --engine=chromium \
          --snapshot "$fullscreen_out" --script fullscreen-exit --data-dir "$home/Fullscreen-$fullscreen_case"
        if grep -qx '\[fullscreen-exit\]' "$fullscreen_out/log.txt" 2>/dev/null; then
          cat "$fullscreen_out/log.txt" >> "$out/log.txt"
          echo >> "$out/log.txt"
        else
          echo "FAIL fullscreen-$fullscreen_case: no log (crashed or never started)" >> "$out/log.txt"
        fi
      done
      # Password field geometry under CSP, in frames, after scrolling/zooming (no HID or capture).
      launch --script password-bounds --data-dir "$home/PasswordBounds"
      # Protected media (DRMWebKitCheck.swift, docs/user/protected-media.md): DRM services' pages in WebKit inside the
      # Chromium build, on loopback pages where "localhost" plays a listed service. The second run, on the same data,
      # checks the relaunch (the tab comes back in WebKit with its cookie). No account, no device.
      for drm in drmwebkit drmwebkit-read; do
        ui_open -g -n -W --env "CFFIXED_USER_HOME=$home" --env "AIRC_SHIP_GATE=${AIRC_SHIP_GATE:-0}" --env "AIRC_WEBKIT_HOSTS=localhost" \
          "$app" --args --engine=chromium --snapshot "$out" --script "$drm" --data-dir "$home/DRMWebKit"
        grep -qx "\[$drm\]" "$out/log.txt" 2>/dev/null || echo "FAIL $drm: the app wrote no log (crashed or never started)" >> "$out/log.txt"
      done
    fi
    launch --script webkitmedia --data-dir "$home/WebKitMedia" --autoplay-policy=no-user-gesture-required
    # The owner's Spotify / picture in picture report (PiPReturnCheck.swift): the tray's clock follows the sounding
    # element, the system picture in picture's return button brings the tab back, Close Player, and (Chromium) picture in
    # picture takes each video's own shape.
    launch --script pipreturn-tray --data-dir "$home/PiPReturnTray" --autoplay-policy=no-user-gesture-required
    launch --script pipreturn-return --data-dir "$home/PiPReturnBack" --autoplay-policy=no-user-gesture-required
    if [[ $engine == chromium ]]; then
      launch --script pipreturn-aspect --data-dir "$home/PiPReturnAspect" --autoplay-policy=no-user-gesture-required
    fi
    launch --script media2 --data-dir "$home/Media2" --autoplay-policy=no-user-gesture-required --disable-features=WebRtcHideLocalIpsWithMdns
    mkdir -p "$home/ParityP16a/Chromium"
    launch --script parityp16a --data-dir "$home/ParityP16a" --autoplay-policy=no-user-gesture-required --disable-features=WebRtcHideLocalIpsWithMdns --airc-data-dir="$home/ParityP16a" --airc-test=parityp16a
    # SB-54 / SB-55: Downloads, the media tray and the call window (MediaLibCheck.swift). No media devices: the "call"
    # page is a canvas stream and silent audio, so macOS never asks for the camera or microphone. Its two peers connect
    # on loopback; without mDNS names for their host candidates the engine sends no multicast on the local network.
    for script in medialib-downloads medialib-media medialib-call; do
      if [[ $engine == chromium && $script == medialib-call ]]; then
        launch --script "$script" --data-dir "$home/${script}" --autoplay-policy=no-user-gesture-required \
          --disable-features=WebRtcHideLocalIpsWithMdns
      elif [[ $engine == chromium ]]; then
        launch --script "$script" --data-dir "$home/${script}" --autoplay-policy=no-user-gesture-required
      else
        launch --script "$script" --data-dir "$home/${script}"
      fi
    done
    # SB-2: Site Controls from the URL field (SiteControlsCheck.swift). WebKit only for now: on Chromium the check uses
    # media devices, and Chromium asks macOS for the microphone even with fake devices, which puts a prompt on the
    # owner's screen (2026-11-06). Run it by hand on Chromium until a device-free version exists.
    if [[ $engine == webkit ]]; then
      launch --script sitecontrols --ephemeral --data-dir "$home/SiteControls"
    fi
    launch --script boostsplus --ephemeral --data-dir "$home/BoostsPlus" "--host-resolver-rules=MAP example.com 127.0.0.1" --disable-features=HttpsUpgrades
    # BST-1: Boosts on loopback pages (BoostsCheck.swift): no flash, Zap, other sites untouched, custom JS on its site only.
    # On Chromium, two tenants of duckdns.org (a private public suffix) are loopback too, by the engine's resolver rule.
    if [[ $engine == chromium ]]; then
      launch --script boosts --ephemeral --data-dir "$home/Boosts" "--host-resolver-rules=MAP *.duckdns.org 127.0.0.1"
    else
      launch --script boosts --ephemeral --data-dir "$home/Boosts"
    fi
    # BST-3: frames, @import, the size as the page's zoom on a 100vh layout, links, updates, Try It On and the gallery
    # (BoostsTwoCheck.swift). On Chromium a registrable domain is loopback by the resolver rule, and Boost links never resolve.
    if [[ $engine == chromium ]]; then
      launch --script boosts2 --ephemeral --data-dir "$home/Boosts2" "--host-resolver-rules=MAP *.airc-boosts.example 127.0.0.1, MAP other-boosts.example 127.0.0.1, MAP aircbrowser.com ~NOTFOUND" --disable-features=HttpsUpgrades
    else
      launch --script boosts2 --ephemeral --data-dir "$home/Boosts2"
    fi
    # boosts3: no Boost in private windows from the first script on, Zap inside same-site frames (another site's frame
    # zapped whole), and on Chromium the frames script for pages it plays in WebKit (BoostsThreeCheck.swift).
    if [[ $engine == chromium ]]; then
      launch --script boosts3 --ephemeral --data-dir "$home/Boosts3" --disable-features=HttpsUpgrades
    else
      launch --script boosts3 --ephemeral --data-dir "$home/Boosts3"
    fi
    # P05: Arc's page palette per Space in two windows and profiles, live theme/appearance/Space changes, none in a
    # private window, Reduce Motion and Transparency, 1x/2x title contrast (ThemeParityCheck.swift).
    launch --script themeparity --ephemeral --data-dir "$home/ThemeParity"
    # Live Calendar on synthetic meetings (CalendarCheck.swift): never the owner's calendars, never the access prompt.
    launch --script calendar --ephemeral --data-dir "$home/Calendar"
    # The sidebar's update button on a fake ready update (UpdateButtonCheck.swift): never the real updater or feed.
    launch --script updatebutton --ephemeral --data-dir "$home/UpdateButton"
    # Crash reports from a synthetic .ips and MetricKit payload (CrashReportsCheck.swift): never the owner's reports.
    launch --script crashreports --ephemeral --data-dir "$home/CrashReports"
    # Follow-ups (FollowupsCheck.swift): favicon retries, the downloads card above the update pill, the Library's back
    # button, a tab dropped onto a pinned split, and "Leave site?" for each pane of one (Chromium's dialog test gate).
    if [[ $engine == chromium ]]; then
      mkdir -p "$home/Followups/Chromium"
      launch --script followups --data-dir "$home/Followups" --airc-data-dir="$home/Followups" --airc-test=modalDialogs
    else
      launch --script followups --ephemeral --data-dir "$home/Followups"
    fi
    # Split View against Arc (SplitParityCheck.swift): tabs dragged onto pinned and Favorite splits, a Favorite split's
    # icon, Arc's pane keys and controls, ⌥-click, and "Leave site?" for each pane on delete and archive (Chromium's gate).
    if [[ $engine == chromium ]]; then
      mkdir -p "$home/SplitParity/Chromium"
      launch --script splitparity --data-dir "$home/SplitParity" --airc-data-dir="$home/SplitParity" --airc-test=modalDialogs
    else
      launch --script splitparity --ephemeral --data-dir "$home/SplitParity"
    fi
    # PW-1 private windows on loopback pages (PrivateWindowCheck.swift): nothing kept, no cookies across sessions or
    # profiles, ⌘T ⌘W ⇧⌘N in the window; and SB-21 Manage Spaces (ManageSpacesCheck.swift): reorder, rename, delete.
    # PW-1 in private windows too: ⌘F, the page's shortcuts first (CB-3), downloads (PrivateWindowExtrasCheck.swift).
    launch --script private --ephemeral --data-dir "$home/Private"
    # WIN-7 several windows (WindowsCheck.swift): ⌘N, each window's own Space and tab, a page moving between windows
    # without a reload, ⌘W and ⇧⌘W per window, the last window closing and coming back, links from other apps (GURL
    # Apple events to the app's own pid); then three windows across a relaunch.
    launch --script windows --ephemeral --data-dir "$home/Windows"
    launch --script windows-write --data-dir "$home/WindowsSession"
    launch --script windows-read --data-dir "$home/WindowsSession"
    launch --script managespaces --ephemeral --data-dir "$home/ManageSpaces"
    # MEM-3's exemption (KeepLoadedCheck.swift): with a 2 s timeout, pinned tabs and Favorites on a listed loopback host
    # stay loaded and an unlisted one unloads; on Chromium also as WebKit pages.
    launch --script keeploaded --ephemeral --data-dir "$home/KeepLoaded" --airc-data-dir="$home/KeepLoaded"
    # SB-45 tab previews on loopback pages (TabPreviewCheck.swift): the dwell, the card beside the row, live and kept
    # pictures, the hide rules, the actions and the setting. Hover drives the rows' own enter and exit handlers: posted
    # mouse moves never reach tracking areas (the window server makes those events), and HID posting isn't allowed.
    launch --script previews --ephemeral --data-dir "$home/Previews"
    # Favicon retries (FaviconRetryCheck.swift): a loopback icon that fails twice then succeeds comes back on the next
    # trigger (row shown, network back, page load), with backoff and no idle timer; private windows never write to disk.
    launch --script favretry --ephemeral --data-dir "$home/FavRetry"
    # P01a: Arc's context menus on every row, Share with the chosen links, clean and Peek-aware copies, folder Markdown,
    # reset asks first, every action in the Command Bar (ParityP01Check.swift).
    launch --script parityp01 --ephemeral --data-dir "$home/ParityP01"
    # K07: AppleScript with Arc's dictionary, sent in-process (no Automation prompt).
    launch --script parityk07 --ephemeral --data-dir "$home/ParityK07"
    # P07a: Command Bar Site Search (Tab/Space into a site, Backspace out, encoding, per-profile lists, input methods,
    # ⌥⌘⌫) (ParityP07Check.swift).
    launch --script parityp07 --data-dir "$home/ParityP07"
    # P09: pinned extensions in the toolbar, popups under their buttons, ⌘E under the puzzle, per-profile pins
    # (ParityP09Check.swift; synthetic unpacked extensions through the engine's test gate, never the owner's).
    mkdir -p "$home/ParityP09/Chromium" && launch --script parityp09 --data-dir "$home/ParityP09" --airc-data-dir="$home/ParityP09" --airc-test=unpackedExtension
    # P01b: Arc's Edit, Format and Help menus, the shortcuts window, every menu-bar command in the Command Bar
    # (ParityP01bCheck.swift).
    launch --script parityp01b --ephemeral --data-dir "$home/ParityP01b"
    # P01c: a Favorite's and a folder's Move to ›, Reset all tabs in this Folder, Turn into Space, the only unnamed
    # Space's header, Shared Quotes' switch (ParityP01cCheck.swift).
    launch --script parityp01c --ephemeral --data-dir "$home/ParityP01c"
    # P08c: Capture in Portrait Mode in the View menu and the Site Control Center's Capture buttons (ParityP08cCheck.swift).
    launch --script parityp08c --ephemeral --data-dir "$home/ParityP08c"
    # P07d: a site search as the profile's default engine, in the URL field, with its fallback (ParityP07dCheck.swift).
    launch --script parityp07d --ephemeral --data-dir "$home/ParityP07d"
    # P03b: Arc's Cycle Tab (⌃⌘→ ⌃⌘←) in last-used order, Esc's order (Command Bar, Peek, find, full screen, sidebar),
    # ⌥⌘⌫ remapped and the history row's ✕, bracket keys on other layouts (ParityP03bCheck.swift).
    launch --script parityp03b --ephemeral --data-dir "$home/ParityP03b"
    # P06b: Little Airc from any app (its global shortcut registered, never pressed), Show/Close Little Airc Windows in
    # the Window, Dock and Command Bar menus, archiving (ParityP06bCheck.swift).
    launch --script parityp06b --ephemeral --data-dir "$home/ParityP06b"
    # P06d: links clicked with ⌥⌘ open in Little Airc; links from other apps (GURL Apple events) follow Settings → Links
    # (ParityP06dCheck.swift).
    launch --script parityp06d --ephemeral --data-dir "$home/ParityP06d"
    # P21b (ParityP21bCheck.swift): the app icon, sounds and haptics settings; on a fake ready update, what a restart
    # would interrupt (music too), restarting by itself while away, See What's New, a quit cancelled by "Leave site?"
    # (Chromium); then two windows, two Spaces and a split across the update's restart, with "Updated!".
    if [[ $engine == chromium ]]; then
      # The cancelled quit reads and answers Chromium's Leave site? through the engine's test hook (its scratch gate).
      mkdir -p "$home/ParityP21b/Chromium"
      launch --script parityp21b --data-dir "$home/ParityP21b" --airc-data-dir="$home/ParityP21b" --airc-test=modalDialogs
    else
      launch --script parityp21b --ephemeral --data-dir "$home/ParityP21b"
    fi
    launch --script p21b-write --data-dir "$home/P21bSession"
    launch --script p21b-read --data-dir "$home/P21bSession"
    # K05: Find and Replace (⌥⌘F) in a focused field and across the page's editable fields and same-origin frame, never
    # a password field, with the page's own undo; Services through the requestor API (ParityK05Check.swift).
    launch --script parityk05 --ephemeral --data-dir "$home/ParityK05"
    # Tidy Titles (AIMaxCheck.swift, docs/user/ai.md) with a fake model on loopback pages: off by default, the
    # "Requires Apple Intelligence" state, short names in the sidebar, the page's own title on hover, hand-renamed
    # tabs and private windows never sent, a stuck model's timeout, the cache file, and off forgets. With Apple
    # Intelligence on, also a timed run of the real on-device model on synthetic titles.
    launch --script aimax --ephemeral --data-dir "$home/AIMax"
    # Tidy tab titles on at launch (the sidebar's first rows start it) and its names kept across a relaunch.
    launch --script aimax-write --data-dir "$home/AIMaxRelaunch"
    launch --script aimax-read --data-dir "$home/AIMaxRelaunch"
    # Ask on Page (AskPageCheck.swift, docs/user/ai.md) with a fake streaming model on loopback pages: off by default, the
    # Command Bar's action and ↩ in ⌘F's Ask mode, the answer streamed with quotes that scroll the page to them, and a page
    # too large, an empty one, a stuck model, no model and a private window refused. With Apple Intelligence on, a real run.
    launch --script askpage --ephemeral --data-dir "$home/AskPage"
    # Link previews (LinkPreviewCheck.swift) with a fake summarizer: ⇧ over a link through its own handler, the card from
    # a page read in the background in the same profile, the session cache, a long press, never sites, private windows.
    launch --script linkpreview --ephemeral --data-dir "$home/LinkPreview"
    # Tidy Downloads (TidyDownloadsCheck.swift) with a fake namer: a PDF download's suggested name from its page and its
    # text (PDFKit), Rename in Library › Downloads (extension kept, a number when taken), private downloads left alone.
    launch --script tidydownloads --ephemeral --data-dir "$home/TidyDownloads"
    # WIN-5 the sidebar on the right (SidebarRightCheck.swift), on loopback pages: both positions at the default, minimum
    # and maximum widths (sidebar, page card, resize edge, traffic lights, tab preview card, drop edges, ⌘L, Library,
    # downloads card and update pill), ⌘S and the reveal from the right edge, and the setting live across windows.
    launch --script sidebarright --ephemeral --data-dir "$home/SidebarRight"
    # SB-36 multi-selection (MultiSelectCheck.swift), on loopback pages: ⌘- and ⇧-click (rows' own handlers), Esc and
    # click-away, the menu's and keys' bulk actions with their undo, and dragging a selection into a folder, across
    # Spaces and onto a second window's sidebar.
    launch --script multiselect --ephemeral --data-dir "$home/MultiSelect"
    # Sidebar feel from the parity audit (SidebarPolishCheck.swift): the reveal dwell rechecked when it ends (the strip's
    # own mouseMoved; key window and pointer stood in), the resize hide point, the 22.7 pt New Space and Library pulls
    # (fed to the pager's track), and the folder open/close curves read back from the rows' layers.
    launch --script sidebarpolish --ephemeral --data-dir "$home/SidebarPolish"
    # CB-5 Capture (CaptureCheck.swift) on a loopback page of colour blocks: the overlay's own handlers, the PNG's size
    # and colours on the run's own pasteboard, Save to a scratch folder, Esc, Share, ⌘ elements, a private window.
    mkdir -p "$home/Smallwins/Chromium" && launch --script smallwins --data-dir "$home/Smallwins" --airc-data-dir="$home/Smallwins" --airc-test=unpackedExtension
    launch --script capture --ephemeral --data-dir "$home/Capture"
    # P08a/Q04: a real Capture pasted into a note, then the same data folder after a relaunch.
    launch --script notescapture --data-dir "$home/NotesCapture"
    launch --script notescapture-read --data-dir "$home/NotesCapture"
    # Notes (docs/user/notes.md): the editor, then the same data folder after a relaunch.
    launch --script notes --data-dir "$home/Notes"
    launch --script notes-read --data-dir "$home/Notes"
    launch --script library2 --ephemeral --data-dir "$home/Library2"
    # DEV-1 (DeveloperModeCheck.swift). Chromium: a remote site mapped to the fixture, and a loopback CDP port in the
    # scratch profile for the console call-site checks (inspector closed and open).
    if [[ $engine == chromium ]]; then
      devport=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
      launch --script devmode --ephemeral --data-dir "$home/DeveloperMode" "--host-resolver-rules=MAP devmode-remote.example 127.0.0.1" \
        --disable-features=HttpsUpgrades "--remote-debugging-port=$devport"
    else
      launch --script devmode --ephemeral --data-dir "$home/DeveloperMode"
    fi
    launch --script arcbits --ephemeral --data-dir "$home/Arcbits"
    # Site Controls and Safari's-engine pages (Followups3Check.swift), on loopback pages: the location in use (the page
    # script's made-up position, never CoreLocation), macOS's privacy answers as a test override (never a prompt, never
    # System Settings), and on Chromium the blocked pop-ups and the WebKit pages ("localhost" plays a listed service):
    # a Boost, the extension buttons (an unpacked test extension, on the engine's test gate: --airc-test decides it at
    # startup), a Little Arc link, unloading and picture in picture. No account, no camera, microphone or screen.
    if [[ $engine == chromium ]]; then
      mkdir -p "$home/Followups3/Chromium"
      ui_open -g -n -W --env "CFFIXED_USER_HOME=$home" --env "AIRC_SHIP_GATE=${AIRC_SHIP_GATE:-0}" --env "AIRC_WEBKIT_HOSTS=localhost" \
        "$app" --args --engine=chromium --snapshot "$out" --script followups3 --data-dir "$home/Followups3" --airc-data-dir="$home/Followups3" \
        --airc-test=unpackedExtension
      grep -qx "\[followups3\]" "$out/log.txt" 2>/dev/null || echo "FAIL followups3: the app wrote no log (crashed or never started)" >> "$out/log.txt"
    else
      launch --script followups3 --ephemeral --data-dir "$home/Followups3"
    fi
    # iCloud sync (ICloudSyncCheck.swift, docs/sync.md) between app instances through a mock CloudKit database in a folder,
    # each with its own fake keychain (a copied key file plays iCloud Keychain): never the real iCloud or Keychain. The first
    # Mac uploads, a second merges, a third replaces, the first gets both and a push; with no backend the page says why.
    for sync_phase in "icloudsync a ICloudA MacBook-Air" "icloudsync-second b ICloudB MacBook-Pro" "icloudsync-replace c ICloudC iMac" \
      "icloudsync-return a ICloudA MacBook-Air"; do
      read -r sync_script sync_keychain sync_data sync_name <<< "$sync_phase"
      launch --script "$sync_script" --data-dir "$home/$sync_data" --sync-mock "$home/ICloudShared/cloud" \
        --sync-keychain "$home/ICloudShared/keychain-$sync_keychain" --sync-device-name "${sync_name//-/ }"
    done
    launch --script icloudsync-unavailable --ephemeral --data-dir "$home/ICloudUnavailable"
    ls "$home/Library" 2>/dev/null | sed 's/^/  wrote in snapshot home: /'
    ls "$out" | tr '\n' ' '; echo
    grep -E "^(PASS|FAIL|FAIL-ENV|SKIP|ENGINE-PASS|ENGINE-FAIL) " "$out/log.txt" | sed "s/^/  [$engine] /" || true
  }
  FAILED=0
  for engine in ${SNAPSHOT_ENGINES//,/ }; do
    if [[ $engine == chromium && $WITH_CHROMIUM != 1 ]]; then echo "== snapshots (chromium): skipped, no framework"; continue; fi
    out="$OUT_ROOT"; [[ $engine == webkit ]] || out="$OUT_ROOT/$engine"
    scenarios "$engine" "$out"
    [[ -f "$out/log.txt" ]] || { echo "[$engine] the app wrote no log (did it start?)" >&2; FAILED=1; continue; }
  done
  [[ $FAILED == 0 ]] || exit 1
  python3 "$ROOT/infra/ui_gate.py" finish "$UI_GATE"
fi

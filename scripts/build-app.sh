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
# Chromium: when `Airc Framework.framework` exists at $CHROMIUM_OUT (default ~/arcfork/chromium/src/out/Airc), a second
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

CHROMIUM_OUT="${CHROMIUM_OUT:-$HOME/arcfork/chromium/src/out/Airc}"
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
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "error: $1 has no usage description for: ${missing[*]}" >&2
    echo "  macOS kills the app the first time a page or sign-in uses one of these (TCC privacy violation)." >&2
    exit 1
  fi
}
check_privacy_keys "$ROOT/apps/browser/Resources/Info.plist"

if [[ $TEST == 1 ]]; then
  echo "== AircKit tests"
  swift test --package-path "$ROOT/packages/AircKit" 2>&1 | grep -E "error|failed|Executed [0-9]+ tests" | tail -3
  [[ ${PIPESTATUS[0]} == 0 ]] || { echo "AircKit tests failed" >&2; exit 1; }
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
  : "${AIRC_UPDATE_FEED:?Dev builds require the operator feed URL}"
  [[ "$AIRC_UPDATE_FEED" == https://* ]] || { echo "AIRC_UPDATE_FEED must be an https URL" >&2; exit 2; }
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
  cp "$ROOT/apps/browser/Resources/Info.plist" "$app/Contents/Info.plist"
  # The app icon (assets/brand/README.md): Info.plist names it with CFBundleIconFile = AppIcon.
  cp "$ROOT/assets/brand/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$app/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" "$app/Contents/Info.plist"
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

echo "== swift build ($CONFIG, WebKit)"
swift_build --package-path "$ROOT/apps/browser" -c "$CONFIG" ${WEBKIT_SCRATCH[@]+"${WEBKIT_SCRATCH[@]}"} \
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
  ENGINE_FLAGS=(--scratch-path "$SCRATCH" -Xswiftc -I -Xswiftc "$ROOT/engine/core/public"
    -Xlinker "$FRAMEWORK/Airc Framework" -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
  swift_build --package-path "$ROOT/apps/browser" -c "$CONFIG" "${ENGINE_FLAGS[@]}" ${TESTING_FLAGS[@]+"${TESTING_FLAGS[@]}"} \
    ${SPARKLE_FLAGS[@]+"${SPARKLE_FLAGS[@]}"} || { echo "Chromium build failed" >&2; exit 1; }
  bundle "$CHROMIUM_APP" "$(swift build --package-path "$ROOT/apps/browser" -c "$CONFIG" --scratch-path "$SCRATCH" ${SPARKLE_FLAGS[@]+"${SPARKLE_FLAGS[@]}"} --show-bin-path)/Airc" chromium
  echo "== also $CHROMIUM_APP (Chromium engine; --engine=webkit still works)"
fi

if [[ -n "$SNAPSHOTS" ]]; then
  rm -rf "$SNAPSHOTS"; mkdir -p "$SNAPSHOTS"
  OUT_ROOT="$(cd "$SNAPSHOTS" && pwd)"
  # Keep the display awake while scenarios run (display-link animations stall once it sleeps), only for this run.
  caffeinate -d -w $$ &
  # A locked screen (the owner stepped away) doesn't stop the run, but windows don't draw and some checks can't hold.
  if ioreg -n Root -d1 2>/dev/null | grep -q '"CGSSessionScreenIsLocked"=Yes'; then
    echo "== warning: the screen is locked; real-event checks that need drawn windows may fail or skip"
  fi
  # Each engine runs the same scenarios. Everything a run writes (store, engine data, caches, defaults) stays in
  # build/snapshot-home/<engine>: CFFIXED_USER_HOME moves the app's home folder there, and Chromium's profiles live
  # in each run's --data-dir. -g: don't take focus on the owner's Mac. -W: wait until the app quits.
  scenarios() {
    local engine=$1 out=$2 home="$ROOT/build/snapshot-home/$1"
    echo "== snapshots ($engine) -> $out"
    rm -rf "$home"; mkdir -p "$home/Library" "$out"
    local app="$APP"; [[ $engine == chromium ]] && app="$CHROMIUM_APP"
    # A scenario writes its log section when it finishes; none means the app crashed or never started.
    launch() {
      open -g -n -W --env "CFFIXED_USER_HOME=$home" --env "AIRC_SHIP_GATE=${AIRC_SHIP_GATE:-0}" "$app" --args --engine="$engine" --snapshot "$out" "$@"
      grep -qx "\[$2\]" "$out/log.txt" 2>/dev/null || echo "FAIL $2: the app wrote no log (crashed or never started)" >> "$out/log.txt"
    }
    launch --script showcase --ephemeral --data-dir "$home/Airc"
    # First run (ON-1…5) on a synthetic Arc import fixture: never the owner's Arc data or Keychain.
    launch --script onboarding --onboarding --ephemeral --data-dir "$home/Onboarding"
    # Relaunch check: one run writes Spaces and tabs, a second run on the same data shows them.
    launch --script persist-write --data-dir "$home/Persist"
    launch --script persist-read --data-dir "$home/Persist"
    # SV-1: a split on screen at quit comes back as it was (panes, order, axis, sizes, focused pane).
    launch --script split-write --data-dir "$home/Split"
    launch --script split-read --data-dir "$home/Split"
    # Real clicks and keys through the window (EventTests.swift): a control that draws but doesn't respond fails.
    launch --script events --ephemeral --data-dir "$home/Events"
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
      for fullscreen_case in native html switch split little; do
        local fullscreen_out="$out/fullscreen-$fullscreen_case"
        mkdir -p "$fullscreen_out"
        rm -f "$fullscreen_out/log.txt"
        open -g -n -W --env "CFFIXED_USER_HOME=$home" --env "AIRC_SHIP_GATE=${AIRC_SHIP_GATE:-0}" \
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
    fi
    # SB-54 / SB-55: Downloads, the media tray and the call window (MediaLibCheck.swift). No media devices: the "call"
    # page is a canvas stream and silent audio, so macOS never asks for the camera or microphone.
    for script in medialib-downloads medialib-media medialib-call; do
      if [[ $engine == chromium ]]; then
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
    # BST-1: Boosts on loopback pages (BoostsCheck.swift): no flash, Zap, other sites untouched, custom JS on its site only.
    launch --script boosts --ephemeral --data-dir "$home/Boosts"
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
    if grep -q "^FAIL " "$out/log.txt"; then echo "[$engine] real-event checks failed" >&2; FAILED=1; fi
  done
  [[ $FAILED == 0 ]] || exit 1
fi

#!/bin/bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
app="$ROOT/build/Airc-Chromium.app"; build_app=1; out="$ROOT/build/release"; identity=${AIRC_SIGN_IDENTITY:--}; profile=${AIRC_NOTARY_PROFILE:-}; auto_notary=1
while [[ $# -gt 0 ]]; do
 case "$1" in
 --app|--output|--identity|--notary-profile) [[ $# -ge 2 && -n "$2" ]] || { echo "Missing value for $1" >&2; exit 2; }; case "$1" in --app) app=$2; build_app=0;; --output) out=$2;; --identity) identity=$2;; --notary-profile) profile=$2; auto_notary=0;; esac; shift 2;;
 --help) echo 'Usage: package.sh [--app APP] [--output DIR] [--identity "Developer ID Application: …"] [--notary-profile PROFILE]'; exit 0;;
 *) echo "Unknown option: $1" >&2; exit 2;; esac
done
[[ $(uname) == Darwin ]] || { echo 'Run on macOS.' >&2; exit 1; }
[[ -z "$profile" || "$identity" != '-' ]] || { echo 'Notarization requires Developer ID signing.' >&2; exit 2; }
mkdir -p "$out"; out=$(cd "$out" && pwd)
work=$(mktemp -d "$out/.package.XXXXXX"); mount="$work/mount"
cleanup() { hdiutil detach "$mount" -quiet 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT
if [[ $build_app == 1 ]]; then
  chromium_out=${CHROMIUM_OUT:-$HOME/arcfork/chromium/src/out/AircRelease}
  [[ -f "$chromium_out/Airc Framework.framework/Airc Framework" ]] || {
    echo 'Release framework missing; set CHROMIUM_OUT to a qualified existing build.' >&2; exit 1;
  }
  # An engine built without generate_about_credits has Chromium's sample page: make the real one from its checkout.
  credits="$chromium_out/gen/components/resources/about_credits.html"
  if [[ ! -f "$credits" || $(wc -c < "$credits") -lt 10000 ]]; then
    echo "== Chromium credits: the engine output has the sample page; generating them from its checkout"
    credits="$work/about_credits.html"
    "$ROOT/scripts/release/chromium-credits.sh" "${CHROMIUM_SRC:-$chromium_out/../..}" "$credits"
  fi
  # A public build: no test code (AIRC_PUBLIC_BUILD, App/TestingGate.swift). Do not inherit a private feed, test
  # defaults, a test identity or a signing identity from a dev shell.
  env -u AIRC_LAUNCH_ARGS -u AIRC_BUNDLE_ID -u AIRC_PASSKEY_ENTITLEMENTS -u AIRC_ICLOUD_ENTITLEMENTS \
    -u AIRC_TELEMETRY_KEY -u AIRC_TELEMETRY_HOST \
    AIRC_PUBLIC_BUILD=1 CHROMIUM_OUT="$chromium_out" AIRC_CHROMIUM_CREDITS="$credits" \
    AIRC_DEV_CHANNEL=0 AIRC_UPDATE_CHANNEL="${AIRC_RELEASE_CHANNEL:-stable}" \
    AIRC_UPDATE_FEED=https://aircbrowser.com/appcast.xml AIRC_SIGN_IDENTITY=- \
    SPARKLE_ROOT="${SPARKLE_ROOT:-$HOME/arcfork/tools/sparkle}" \
    "$ROOT/scripts/build-app.sh"
fi
[[ $(uname) == Darwin && -d "$app/Contents" ]] || { echo 'Run on macOS with a built app.' >&2; exit 1; }
# All shared engine/credits reads finished in build-app.sh; the coordinator can release its ship lock.
touch "$out/engine-read.done"
mkdir -p "$work/stage/.background"
ditto "$app" "$work/stage/Airc.app"
plist="$work/stage/Airc.app/Contents/Info.plist"
# Only our newly compiled public bundle receives the permanent stable identity here.
# --app is deliberately not repaired: it must already satisfy the same gate.
if [[ $build_app == 1 ]]; then
 python3 "$ROOT/scripts/release/stable-metadata.py" "$plist"
fi
# Supplied apps must already have release metadata; never silently sanitize one.
python3 "$ROOT/scripts/release/check-release.py" "$work/stage/Airc.app"
"$ROOT/scripts/release/scan-bundle.sh" "$work/stage/Airc.app"
# iCloud sync (docs/release.md, "iCloud sync"): a Developer ID provisioning profile for this bundle ID in
# AIRC_ICLOUD_PROFILE_DIR (default ~/arcfork/secrets) is embedded before signing, and the main app alone gets its CloudKit
# entitlements. Without one the release is unchanged. Team and app identifiers come from the profile, never the repo.
icloud_entitlements=
if [[ "$identity" != '-' ]]; then
 icloud_entitlements=$(python3 "$ROOT/scripts/release/icloud.py" prepare "$work/stage/Airc.app" "$work")
fi
AIRC_ICLOUD_ENTITLEMENTS="$icloud_entitlements" python3 "$ROOT/scripts/release/sign.py" "$work/stage/Airc.app" "$identity"
if [[ "$identity" != '-' ]]; then
 python3 "$ROOT/scripts/release/check-entitlements.py" "$work/stage/Airc.app"
fi
# The signature and the embedded profile agree (codesign -d --entitlements, security cms -D), helpers have no iCloud.
[[ -z "$icloud_entitlements" ]] || python3 "$ROOT/scripts/release/icloud.py" verify "$work/stage/Airc.app"
export AIRC_NOTARY_KEYCHAIN=${AIRC_NOTARY_KEYCHAIN:-${AIRC_SIGN_KEYCHAIN:-}}
notary_args=()
[[ -z "$AIRC_NOTARY_KEYCHAIN" ]] || notary_args=(--keychain "$AIRC_NOTARY_KEYCHAIN")
# Auto-use the configured profile only when it exists. Authentication/network errors
# are failures, not permission to silently produce an unnotarized release.
if [[ "$identity" != - && $auto_notary == 1 && -n "$profile" ]]; then
  probe=$(mktemp "$work/.notary-probe.XXXXXX")
  if xcrun notarytool history --keychain-profile "$profile" ${notary_args[@]+"${notary_args[@]}"} > "$probe" 2>&1; then
    : # Profile is usable.
  elif grep -q 'No Keychain password item found' "$probe"; then
    echo 'Notarization pending: store credentials in AIRC_NOTARY_PROFILE in the selected keychain.'
    profile=
  else
    rm -f "$probe"
    echo 'Could not check notarization credentials; retry after checking access/network.' >&2
    exit 1
  fi
  rm -f "$probe"
fi
if [[ "$identity" != - && -z "$profile" ]]; then
 echo 'Developer ID signed; notarization pending AIRC_NOTARY_PROFILE credentials.'
fi
if [[ -n "$profile" ]]; then
 ditto -c -k --keepParent "$work/stage/Airc.app" "$work/submission.zip"
 "$ROOT/scripts/release/notarize.sh" --profile "$profile" "$work/submission.zip" "$work/stage/Airc.app"
 cp "$work/submission.zip.notary-log.json" "$out/app-notary-log.json"
 rm "$work/submission.zip"
fi
if [[ ${AIRC_KEEP_RELEASE_APP:-0} == 1 ]]; then
 [[ ! -e "$out/Airc.app" ]] || { echo 'Release app already exists' >&2; exit 1; }
 ditto "$work/stage/Airc.app" "$out/Airc.app"
fi
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
[[ "$version-$build" != *[!a-zA-Z0-9._-]* ]] || { echo 'Unsafe version string' >&2; exit 1; }
final="$out/Airc-$version-$build.dmg"
[[ ! -e "$final" ]] || { echo "Refusing to replace $final" >&2; exit 1; }
ln -s /Applications "$work/stage/Applications"
swift "$ROOT/infra/release/background.swift" "$work/stage/.background/install.png" "$ROOT/assets/brand/airc-holographic.png"
cp "$ROOT/assets/brand/AppIcon.icns" "$work/stage/.VolumeIcon.icns"
hdiutil create -quiet -fs APFS -format UDRW -volname Airc -srcfolder "$work/stage" "$work/writable.dmg"
mkdir "$mount"
hdiutil attach -quiet -nobrowse -mountpoint "$mount" "$work/writable.dmg"
clang -Wno-deprecated-declarations -framework Foundation -framework CoreServices "$ROOT/infra/release/alias.m" -o "$work/alias"
"$work/alias" "$mount/.background/install.png" "$work/background.alias"
python3 "$ROOT/scripts/release/layout.py" "$mount" "$work/background.alias"
# Mark the volume icon and instruct Finder to open this directory when mounted.
xcrun SetFile -a C "$mount"
bless --folder "$mount" --openfolder "$mount" 2>/dev/null || true

sync
hdiutil detach -quiet "$mount"
hdiutil convert -quiet "$work/writable.dmg" -format ULFO -o "$final"
if [[ "$identity" != '-' ]]; then
  python3 "$ROOT/scripts/release/sign.py" "$final" "$identity"
fi
if [[ -n "$profile" ]]; then "$ROOT/scripts/release/notarize.sh" --profile "$profile" "$final"; fi
hdiutil verify "$final"
"$ROOT/scripts/release/scan-bundle.sh" "$final"
"$ROOT/scripts/release/check-release.sh" "$final"
printf 'DMG: %s\n' "$final"

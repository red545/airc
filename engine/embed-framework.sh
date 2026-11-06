#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Embed and sign a built framework without modifying the Chromium build output.
set -euo pipefail
app=${1:?Usage: engine/embed-framework.sh APP CHROMIUM_OUT}
chromium_out=${2:?Chromium output directory required}
fw_name="Airc Framework"
identity=${AIRC_SIGN_IDENTITY:--}
mkdir -p "$app/Contents/Frameworks"
[[ ! -e "$app/Contents/Frameworks/$fw_name.framework" ]] || {
  echo 'Framework already embedded; use a fresh app bundle.' >&2; exit 1;
}
cp -cR "$chromium_out/$fw_name.framework" "$app/Contents/Frameworks/"
version=$(ls "$app/Contents/Frameworks/$fw_name.framework/Versions" | grep -v Current)
# Entitlements: Chrome's, plus disable-library-validation for ad-hoc signatures.
ents=$(mktemp -d "$(dirname "$app")/.airc-entitlements.XXXXXX")
trap 'rm -rf "$ents"' EXIT
mkdir -p "$ents"
dlv() {
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$1" >/dev/null 2>&1 || true
}
# Share the reviewed minimal entitlements with release packaging.
config="$(cd "$(dirname "$0")/../infra/release" && pwd)"
for kind in app renderer gpu helper; do cp "$config/$kind.entitlements.plist" "$ents/$kind.plist"; done
# Only the normal utility helper loads the Google-signed CDM. Keep the browser
# and other Developer ID helpers under library validation.
cp "$(dirname "$0")/cdm-helper.entitlements.plist" "$ents/cdm-helper.plist"
if [[ "$identity" == "-" ]]; then
  for f in "$ents"/*.plist; do dlv "$f"; done
fi

sign() {
  local timestamp=--timestamp
  [[ "$identity" != - ]] || timestamp=--timestamp=none
  codesign --force "$timestamp" --options runtime --sign "$identity" "$@"
}
fwv="$app/Contents/Frameworks/$fw_name.framework/Versions/$version"
for lib in "$fwv"/Libraries/*.dylib; do [[ ! -e "$lib" ]] || sign "$lib"; done
for helper in "$fwv"/Helpers/*.app "$fwv"/Helpers/chrome_crashpad_handler "$fwv"/Helpers/app_mode_loader "$fwv"/Helpers/web_app_shortcut_copier; do
  [[ -e "$helper" ]] || continue
  case "$helper" in
    *" Helper.app" | *" Helper (Aperitif).app") sign --entitlements "$ents/cdm-helper.plist" "$helper" ;;
    *"(Renderer).app" | *"(Aperitif Renderer).app") sign --entitlements "$ents/renderer.plist" "$helper" ;;
    *"(GPU).app" | *"(Aperitif GPU).app") sign --entitlements "$ents/gpu.plist" "$helper" ;;
    *) sign --entitlements "$ents/helper.plist" "$helper" ;;
  esac
done
sign "$app/Contents/Frameworks/$fw_name.framework"
sign --entitlements "$ents/app.plist" "$app"
codesign --verify --deep --strict "$app"

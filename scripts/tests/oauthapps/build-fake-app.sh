#!/bin/bash
# oauthapps: builds "Fake Desktop App.app" (FakeDesktopApp.swift) into <out dir> (default build/oauthapps) and
# registers it with Launch Services, so `airc-oauthtest:` links go to it. Test Macs only. Unregister and delete it
# with `build-fake-app.sh --remove [<out dir>]` when the checks are done.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
lsreg=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [[ ${1:-} == --remove ]]; then
  out=${2:-build/oauthapps}
  app="$out/Fake Desktop App.app"
  [[ -d $app ]] && "$lsreg" -u "$app" || true
  rm -rf "$app"
  exit 0
fi
out=${1:-build/oauthapps}
app="$out/Fake Desktop App.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cat >"$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>org.airc.test.fakedesktopapp</string>
  <key>CFBundleName</key><string>Fake Desktop App</string>
  <key>CFBundleDisplayName</key><string>Fake Desktop App</string>
  <key>CFBundleExecutable</key><string>FakeDesktopApp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>Fake Desktop App sign-in</string>
    <key>CFBundleURLSchemes</key><array><string>airc-oauthtest</string></array>
  </dict></array>
</dict></plist>
EOF
swiftc -O -o "$app/Contents/MacOS/FakeDesktopApp" "$here/FakeDesktopApp.swift"
codesign -s - -f "$app" >/dev/null 2>&1 || true
"$lsreg" -f "$app"
echo "$app"

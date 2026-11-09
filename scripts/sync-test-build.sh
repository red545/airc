#!/bin/bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "$0")/.."
source "$HOME/arcfork/setup/signing/signing.env"
[[ -n "${AIRC_SIGN_IDENTITY:-}" && "$AIRC_SIGN_IDENTITY" != - ]]
# Select Xcode's matching compiler, SDK and FoundationModels macros, not the CLT SDK inherited by a shell.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export SDKROOT="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
export PATH="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin:$HOME/arcfork/tools/depot_tools/python-bin:/usr/bin:/bin:/usr/sbin:/sbin"
swift --version
python3 - <<'PY'
import shutil
assert shutil.disk_usage('.').free >= 15 * 1024**3, 'Less than 15 GiB free'
PY
swift test --package-path packages/AircKit --filter Sync 2>&1 | python3 infra/xctest_summary.py
# The normal release compiler and current qualified Chromium framework, with test hooks enabled.
env AIRC_SIGN_IDENTITY=- AIRC_DEV_CHANNEL=0 AIRC_TELEMETRY_KEY= scripts/build-app.sh --no-test
python3 - <<'PY'
from pathlib import Path
import plistlib
p = Path('build/Airc-Chromium.app/Contents/Info.plist')
d = plistlib.loads(p.read_bytes())
d['CFBundleIdentifier'] = 'com.aircbrowser.Airc'
d['CFBundleShortVersionString'] = '0.0.1'
d['CFBundleVersion'] = '1'
d.pop('CFBundleURLTypes', None)
d.pop('CFBundleDocumentTypes', None)
p.write_bytes(plistlib.dumps(d))
PY
export AIRC_ICLOUD_ENTITLEMENTS
AIRC_ICLOUD_ENTITLEMENTS=$(python3 scripts/release/icloud.py prepare build/Airc-Chromium.app build)
[[ -n "$AIRC_ICLOUD_ENTITLEMENTS" ]] || { echo 'FAIL: no iCloud provisioning profile'; exit 1; }
python3 scripts/release/sign.py build/Airc-Chromium.app "$AIRC_SIGN_IDENTITY"
python3 scripts/release/icloud.py verify build/Airc-Chromium.app
python3 - <<'PY'
import sys
sys.path.insert(0, 'scripts/release')
import icloud
ent = icloud.signed_entitlements('build/Airc-Chromium.app')
print('Production:', ent.get('com.apple.developer.icloud-container-environment') == 'Production')
print('Push entitlement:', isinstance(ent.get('com.apple.developer.aps-environment'), str))
PY

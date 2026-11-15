#!/bin/bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Run on the dedicated build Mac from an exported source tree, under its build lock.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DEST="$HOME/arcfork/tools/airc-ui-driver"
mkdir -p "$DEST"
chmod 700 "$DEST"
source "$HOME/arcfork/setup/signing/signing.env"
: "${AIRC_SIGN_IDENTITY:?Developer ID identity required}"
: "${AIRC_SIGN_KEYCHAIN:?Dedicated signing keychain required}"
: "${AIRC_SIGN_KEYCHAIN_PASSWORD_FILE:?Dedicated keychain password file required}"
export AIRC_SIGN_IDENTITY AIRC_SIGN_KEYCHAIN AIRC_SIGN_KEYCHAIN_PASSWORD_FILE
python3 - "$ROOT" "$DEST" <<'PY'
from pathlib import Path
import hashlib, os, plistlib, subprocess, sys
root, dest = map(Path, sys.argv[1:])
source = root / 'infra/ui-driver/main.swift'
binary = dest / 'airc-ui-driver'
mark = dest / 'source.sha256'
digest = hashlib.sha256(source.read_bytes()).hexdigest()
if binary.exists():
    if not mark.exists() or mark.read_text().strip() != digest:
        sys.exit('Installed stable driver differs; leave it intact and coordinate an explicit upgrade.')
else:
    candidate = dest / 'airc-ui-driver.new'
    subprocess.run(['xcrun', 'swiftc', '-O', '-framework', 'AppKit', '-framework', 'ApplicationServices', str(source), '-o', str(candidate)], check=True)
    password = Path(os.environ['AIRC_SIGN_KEYCHAIN_PASSWORD_FILE']).expanduser().read_text().rstrip('\n')
    unlocked = subprocess.run(['security', 'unlock-keychain', '-p', password, os.environ['AIRC_SIGN_KEYCHAIN']], capture_output=True)
    if unlocked.returncode:
        sys.exit('Dedicated signing keychain could not be unlocked')
    subprocess.run(['codesign', '--force', '--sign', os.environ['AIRC_SIGN_IDENTITY'], '--keychain', os.environ['AIRC_SIGN_KEYCHAIN'], '--identifier', 'org.airc.ui-driver', '--options', 'runtime', '--timestamp', str(candidate)], check=True)
    subprocess.run(['codesign', '--verify', '--strict', str(candidate)], check=True)
    subprocess.run([str(candidate), '--self-test'], check=True)
    candidate.replace(binary)
    mark.write_text(digest + '\n')
subprocess.run(['codesign', '--verify', '--strict', str(binary)], check=True)
agent = dest / 'org.airc.ui-driver.plist'
agent.write_bytes(plistlib.dumps({'Label': 'org.airc.ui-driver', 'ProgramArguments': [str(binary), '--serve'],
    'RunAtLoad': True, 'KeepAlive': True, 'LimitLoadToSessionType': 'Aqua',
    'StandardOutPath': str(dest / 'service.log'), 'StandardErrorPath': str(dest / 'service-error.log')}))
domain = 'gui/' + str(os.getuid())
if subprocess.run(['launchctl', 'print', domain + '/org.airc.ui-driver'], capture_output=True).returncode:
    subprocess.run(['launchctl', 'bootstrap', domain, str(agent)], check=True)
print('Stable UI driver installed; owner permission grants are separate.')
PY

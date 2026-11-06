#!/bin/bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Signed scratch Sparkle app, isolated home/identity and ephemeral loopback feed. Never opens Airc.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
: "${AIRC_SIGN_IDENTITY:?Developer ID identity required}"
[[ $AIRC_SIGN_IDENTITY != - ]] || exit 2
export AIRC_PROOF_FROM_IDENTITY="$AIRC_SIGN_IDENTITY" AIRC_PROOF_TO_IDENTITY="$AIRC_SIGN_IDENTITY"
export AIRC_PROOF_CHANNEL=dev
export AIRC_PROOF_DIR="$ROOT/build/local-feed-proof"
mkdir -p "$ROOT/build"
# Exercise the OLD app's ATS dictionary too: the transition feed references loopback enclosures.
# The fixture owns no browser data and uses CFFIXED_USER_HOME, open -g, and a unique bundle ID.
python3 - "$ROOT" <<'PY'
from pathlib import Path
import shlex,sys
root=Path(sys.argv[1])
s=(root/'infra/release/test-updater/run.sh').read_text()
s=s.replace('ROOT=$(cd "$(dirname "$0")/../../.." && pwd)', 'ROOT='+shlex.quote(str(root)))
s=s.replace("'NSAllowsLocalNetworking':True,'NSAllowsArbitraryLoads':True", "'NSAllowsArbitraryLoadsInWebContent':True")
(root/'build/prove-local-run.sh').write_text(s)
PY
bash "$ROOT/build/prove-local-run.sh"

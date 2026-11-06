#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Scheduled 01:15 UTC wrapper. The daytime --ship loop stays private.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
config=${AIRC_RELEASE_CONFIG:-$(dirname "$ROOT")/airc.env}
[[ ! -f "$config" ]] || source "$config"
status="${AIRC_STATUS_DIR:-$(dirname "$ROOT")/status}"
before=$(ls -td "$status"/runs/*/ 2>/dev/null | head -1 || true)
upload_config=${AIRC_PUBLIC_UPLOAD_CONFIG:-$(dirname "$ROOT")/secrets/public-release.env}
[[ ! -f "$upload_config" ]] || source "$upload_config"
"$ROOT/infra/nightly.sh"
after=$(ls -td "$status"/runs/*/ 2>/dev/null | head -1)
[[ "$before" != "$after" ]] || { echo 'Nightly did not create a new run'; exit 1; }
python3 "$ROOT/scripts/release/green.py" "$ROOT" "$after" "$(git -C "$ROOT" rev-parse HEAD)" --check
# The lead can hold public promotion (a known issue on main): the private nightly above still ran.
hold="$status/public-hold"
if [[ -f "$hold" ]]; then
 echo "Public nightly held: $(head -1 "$hold")"
 exit 0
fi
# Storage is provisioned only after the first fully qualified public candidate.
if [[ -z ${AIRC_BLOB_BASE_URL:-} || -z ${BLOB_READ_WRITE_TOKEN:-} || -z ${AIRC_VERCEL_SCOPE:-} || -z ${AIRC_VERCEL_PROJECT_DIR:-} ]]; then
 echo 'Public nightlies pending private Blob configuration; the existing nightly is complete.'
 exit 0
fi
# A red run, unavailable Mac or changed app sources cannot promote a nightly.
"$ROOT/scripts/release/release.sh" --channel nightly --green-run "$after"
base="${AIRC_ARTIFACTS_DIR:-$(dirname "$ROOT")/artifacts}/release/nightly"
stage=$(python3 - "$base" <<'PY'
import pathlib,sys,json
p=pathlib.Path(sys.argv[1]); choices=[]
for f in p.glob('*/release.json'):
 m=json.loads(f.read_text())
 if m['qualified']: choices.append((int(m['build']),f.parent))
print(max(choices)[1])
PY
)
"$ROOT/scripts/release/upload.sh" "$stage" --go

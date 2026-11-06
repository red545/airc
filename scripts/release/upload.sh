#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
config=${AIRC_PUBLIC_UPLOAD_CONFIG:-$(dirname "$ROOT")/secrets/public-release.env}
[[ ! -f "$config" ]] || source "$config"
exec python3 "$ROOT/scripts/release/upload.py" "$@"

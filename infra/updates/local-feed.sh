#!/bin/bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Build Mac: install the loopback-only owner feed. --proof uses an isolated scratch service.
set -euo pipefail
trap 'rc=$?; if [[ $rc != 0 ]]; then echo "local-feed.sh: installer failed (exit $rc)" >&2; fi' EXIT
root=$(cd "$(dirname "$0")/../.." && pwd)
python3 "$root/infra/updates/install-feed.py" "$root" "$@"

#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
set -euo pipefail
exec python3 "$(cd "$(dirname "$0")" && pwd)/apply.py" "$@"

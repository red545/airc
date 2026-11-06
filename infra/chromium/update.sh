#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Prepare an isolated Linux source tree only; never start a Mac build.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
export PATH="${DEPOT_TOOLS:-$HOME/arcfork/depot_tools}:$PATH"
export DEPOT_TOOLS_UPDATE=0
exec python3 "$here/update.py" "$@"

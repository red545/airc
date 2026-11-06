#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DIR=${AIRC_UPDATES_DIR:-$(dirname "$ROOT")/updates}
mkdir -p "$DIR/dev"
if [[ ! -e "$DIR/dev/appcast.xml" ]]; then
  printf '%s\n' '<?xml version="1.0" encoding="utf-8"?><rss version="2.0"><channel><title>Airc dev</title></channel></rss>' > "$DIR/dev/appcast.xml"
fi
if ! tmux has-session -t airc-updates 2>/dev/null; then
  tmux new-session -d -s airc-updates "$(printf '%q ' python3 "$ROOT/infra/updates/server.py" "$DIR")"
fi
tailscale serve --bg --https=8482 http://localhost:3482

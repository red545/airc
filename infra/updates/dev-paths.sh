#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Sourced by both dev preparation and publication so feed/cache/ack paths agree.
if [[ -n ${AIRC_SCRATCH_PUBLISH_ROOT:-} ]]; then
  AIRC_SCRATCH_PUBLISH_ROOT=$(python3 "$(dirname "${BASH_SOURCE[0]}")/scratch_paths.py" "$AIRC_SCRATCH_PUBLISH_ROOT")
  DEV_FEED_DIR="$AIRC_SCRATCH_PUBLISH_ROOT/feed"
  DEV_CACHE_DIR="$AIRC_SCRATCH_PUBLISH_ROOT/cache"
else
  DEV_FEED_DIR="$HOME/arcfork/updates-local"
  DEV_CACHE_DIR="$HOME/arcfork/updates-cache.noindex/dev"
fi

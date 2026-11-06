#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Only deferred uploads use this gate. A forced-slow flag exercises offline publication.
link_ok() {
  [[ ${AIRC_DEFER_FORCE_SLOW:-0} != 1 && ! -e "$STATUS/deferred-force-slow" ]] || return 1
  local t0 t1 limit=${AIRC_SHIP_MIN_LINK_SECONDS:-10}
  t0=$(date +%s)
  timeout "$((limit + 5))" ssh -o BatchMode=yes -o ConnectTimeout=15 "${AIRC_MAC_HOST:-mac}" 'head -c 2000000 /dev/zero' > /dev/null 2>&1 || return 1
  t1=$(date +%s)
  (( t1 - t0 <= limit ))
}

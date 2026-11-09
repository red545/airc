// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#ifndef AIRC_CORE_AIRC_BLOCKING_FFI_H_
#define AIRC_CORE_AIRC_BLOCKING_FFI_H_
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Stable C ABI. UTF-8 inputs are borrowed; handles and outputs are caller-owned.
typedef struct BlockingEngine AircBlockingEngine;
typedef struct { uint8_t* data; size_t len; } AircBlockingBytes;
typedef struct {
  int32_t valid;
  int32_t blocked;
  AircBlockingBytes rewritten_url;
  AircBlockingBytes csp;
} AircBlockingDecision;
// Free both output buffers with airc_blocking_bytes_free, including empty ones.
AircBlockingDecision airc_blocking_match(const AircBlockingEngine*, const uint8_t*, size_t,
    const uint8_t*, size_t, const uint8_t*, size_t, const uint8_t*, size_t);
uint32_t airc_blocking_abi_version(void);
AircBlockingEngine* airc_blocking_create(const uint8_t*, size_t);
void airc_blocking_destroy(AircBlockingEngine*);
void airc_blocking_bytes_free(AircBlockingBytes);
// UTF-8 URL, initiator URL, resource type, HTTP method, each with byte length.
int32_t airc_blocking_check(const AircBlockingEngine*, const uint8_t*, size_t,
    const uint8_t*, size_t, const uint8_t*, size_t, const uint8_t*, size_t);
AircBlockingBytes airc_blocking_match_json(const AircBlockingEngine*, const uint8_t*, size_t,
    const uint8_t*, size_t, const uint8_t*, size_t, const uint8_t*, size_t);
AircBlockingBytes airc_blocking_cosmetics(const AircBlockingEngine*, const uint8_t*, size_t);
AircBlockingBytes airc_blocking_generic_cosmetics(const AircBlockingEngine*,
    const uint8_t*, size_t, const uint8_t*, size_t);
AircBlockingBytes airc_blocking_serialize(const AircBlockingEngine*);
AircBlockingBytes airc_blocking_webkit_rules(const uint8_t*, size_t);
AircBlockingBytes airc_blocking_webkit(const uint8_t*, size_t);
#ifdef __cplusplus
}
#endif
#endif

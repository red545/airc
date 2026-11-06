// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#ifndef AIRC_CORE_AIRC_PAGE_LIMITS_H_
#define AIRC_CORE_AIRC_PAGE_LIMITS_H_

#include <stddef.h>

#include <string_view>

namespace airc {

inline constexpr size_t kMaxPageMessageKind = 32;
inline constexpr size_t kMaxEvaluationResultBytes = 4 * 1024 * 1024;

inline constexpr size_t MaxPageMessageBytes(std::string_view kind) {
  return kind == "notification" || kind == "nowPlaying" ? 1280 * 1024
                                                        : 64 * 1024;
}

}

#endif

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#ifndef AIRC_CORE_AIRC_DRM_NETWORK_H_
#define AIRC_CORE_AIRC_DRM_NETWORK_H_
#include <string_view>
#include <vector>
#include "airc/core/airc_drm_policy.h"
#include "url/gurl.h"
namespace airc {
inline std::vector<GURL> ComponentDownloadURLs(
    std::string_view id, const std::vector<GURL>& urls) {
  if (!g_airc_protected_content_enabled || id != kWidevineComponentId) return urls;
  std::vector<GURL> secure;
  for (const auto& url : urls) {
    if (url.SchemeIs("https")) secure.push_back(url);
  }
  return secure;
}
}
#endif

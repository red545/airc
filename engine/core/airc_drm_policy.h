// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#ifndef AIRC_CORE_AIRC_DRM_POLICY_H_
#define AIRC_CORE_AIRC_DRM_POLICY_H_
#include <string_view>
// Set only by the Airc delegate; upstream tools retain their original behavior.
inline bool (*g_airc_protected_content_enabled)() = nullptr;
namespace airc {
inline constexpr char kProtectedContentPref[] = "airc.protected_content_enabled";
inline constexpr char kWidevineComponentId[] = "oimompecagnajdejgnnjijobebaeigek";
// Called by the component service on the browser UI sequence. Omitting a
// disabled CDM here excludes it from automatic/manual requests and their pings.
// All other components retain their upstream policy and network behavior.
inline bool AllowComponentUpdate(std::string_view id) {
  return id != kWidevineComponentId || !g_airc_protected_content_enabled ||
         g_airc_protected_content_enabled();
}
inline bool ComponentBackgroundDownloader(std::string_view id, bool upstream) {
  return (id != kWidevineComponentId || !g_airc_protected_content_enabled) && upstream;
}
bool ProtectedContentEnabled();
}
#endif

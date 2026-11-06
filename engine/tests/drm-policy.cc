// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#include "engine/core/airc_drm_policy.h"
#include <cassert>
int main() {
  assert(airc::AllowComponentUpdate(airc::kWidevineComponentId));
  assert(airc::ComponentBackgroundDownloader(airc::kWidevineComponentId, true));
  g_airc_protected_content_enabled = +[] { return false; };
  assert(!airc::AllowComponentUpdate(airc::kWidevineComponentId));
  assert(airc::AllowComponentUpdate("crlset"));
  assert(airc::AllowComponentUpdate("any-other-component"));
  assert(airc::ComponentBackgroundDownloader("crlset", true));
  assert(!airc::ComponentBackgroundDownloader("crlset", false));
  assert(!airc::ComponentBackgroundDownloader(airc::kWidevineComponentId, true));
  g_airc_protected_content_enabled = +[] { return true; };
  assert(airc::AllowComponentUpdate(airc::kWidevineComponentId));
  assert(airc::AllowComponentUpdate("crlset"));
}

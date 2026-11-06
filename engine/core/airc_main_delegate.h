// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#ifndef AIRC_CORE_AIRC_MAIN_DELEGATE_H_
#define AIRC_CORE_AIRC_MAIN_DELEGATE_H_

#include <optional>

#include "chrome/app/chrome_main_delegate.h"

namespace airc {

class AircMainDelegate : public ChromeMainDelegate {
 public:
  explicit AircMainDelegate(const StartupTimestamps& timestamps);
  ~AircMainDelegate() override;

 protected:
  void CreateThreadPool(std::string_view name) override;
  std::optional<int> BasicStartupComplete() override;
  std::optional<int> PostEarlyInitialization(InvokedIn invoked_in) override;
  void PreSandboxStartup() override;
  content::ContentBrowserClient* CreateContentBrowserClient() override;
  content::ContentRendererClient* CreateContentRendererClient() override;
};

void OnEngineStarted();
void OnEngineShuttingDown();
void ReleaseAppKeepAlive();

}

#endif

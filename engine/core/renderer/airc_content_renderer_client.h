// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#ifndef AIRC_CORE_RENDERER_AIRC_CONTENT_RENDERER_CLIENT_H_
#define AIRC_CORE_RENDERER_AIRC_CONTENT_RENDERER_CLIENT_H_

#include <memory>

#include "chrome/renderer/chrome_content_renderer_client.h"

namespace airc {

class AircRenderThreadObserver;

class AircContentRendererClient : public ChromeContentRendererClient {
 public:
  AircContentRendererClient();
  ~AircContentRendererClient() override;

  void RenderThreadStarted() override;
  void RenderFrameCreated(content::RenderFrame* render_frame) override;
  void RunScriptsAtDocumentStart(content::RenderFrame* render_frame) override;

 private:
  std::unique_ptr<AircRenderThreadObserver> observer_;
};

}

#endif

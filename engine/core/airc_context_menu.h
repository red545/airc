// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#ifndef AIRC_CORE_AIRC_CONTEXT_MENU_H_
#define AIRC_CORE_AIRC_CONTEXT_MENU_H_

#include <memory>

namespace content {
class WebContents;
class WebContentsViewDelegate;
}

namespace airc {

std::unique_ptr<content::WebContentsViewDelegate> CreateViewDelegate(
    content::WebContents* contents);

}

#endif

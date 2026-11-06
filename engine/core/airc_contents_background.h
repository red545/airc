// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

// Copyright 2026 Ardia. Apache-2.0.

#ifndef AIRC_CORE_AIRC_CONTENTS_BACKGROUND_H_
#define AIRC_CORE_AIRC_CONTENTS_BACKGROUND_H_

#include <optional>

#include "third_party/skia/include/core/SkColor.h"

namespace content {
class WebContents;
}

namespace airc {

void SetContentsBackgroundColor(content::WebContents* contents, std::optional<SkColor> color);

std::optional<SkColor> ContentsBackgroundColor(content::WebContents* contents);

void SetHostPageBaseBackgroundColor(content::WebContents* contents, std::optional<SkColor> color);

void MarkAheadBlank(content::WebContents* contents);

void EndAheadBlank(content::WebContents* contents);

bool InAheadBlank(content::WebContents* contents);

}

#endif

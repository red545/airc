// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

// Copyright 2026 Ardia. Apache-2.0.

#ifndef AIRC_CORE_AIRC_PICTURE_IN_PICTURE_H_
#define AIRC_CORE_AIRC_PICTURE_IN_PICTURE_H_

#include <string>

namespace content {
class WebContents;
}

namespace airc {

void StartPictureInPictureObserver();

bool PictureInPictureTracing();
void TracePictureInPicture(const std::string& line);

void TraceAutoPictureInPictureInputs(content::WebContents* contents, const char* when);

}

#endif

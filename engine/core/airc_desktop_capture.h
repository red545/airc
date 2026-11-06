// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

// Copyright 2026 Ardia. Apache-2.0.

#ifndef AIRC_CORE_AIRC_DESKTOP_CAPTURE_H_
#define AIRC_CORE_AIRC_DESKTOP_CAPTURE_H_

#include <string>

namespace content {
struct MediaStreamRequest;
class WebContents;
}

namespace airc {

void AllowDesktopCapture(content::WebContents* contents,
                         const std::string& source,
                         const std::string& frame_id,
                         const std::string& origin,
                         const std::string& audio);

bool IsDesktopCaptureSystemAudioSupported();
bool IsDesktopCaptureApplicationAudioSupported();

void ApplyDesktopCaptureGrant(content::WebContents* contents,
                              content::MediaStreamRequest& request);

}

#endif

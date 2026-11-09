// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#ifndef AIRC_CORE_AIRC_DEVELOPER_COMMANDS_H_
#define AIRC_CORE_AIRC_DEVELOPER_COMMANDS_H_

#include <cmath>
#include <string_view>

namespace content { class WebContents; }

namespace airc {
// Cancels pending opens and closes even a not-yet-docked frontend.
void CloseDeveloperTools(content::WebContents* contents);
inline bool IsDeveloperPanel(std::string_view panel) {
  return panel == "console" || panel == "network" || panel == "elements";
}
// Coordinates are viewport DIPs from the top left, not screen pixels or page CSS coordinates.
inline bool IsInspectPoint(double x, double y, double width, double height) {
  return std::isfinite(x) && std::isfinite(y) && x >= 0 && y >= 0 &&
         x < width && y < height;
}
}  // namespace airc
#endif

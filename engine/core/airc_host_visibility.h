// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

// Copyright 2026 Ardia. Apache-2.0.

#ifndef AIRC_CORE_AIRC_HOST_VISIBILITY_H_
#define AIRC_CORE_AIRC_HOST_VISIBILITY_H_

#include <optional>

namespace content {
class WebContents;
}

namespace airc {

void NoteTabShownByHost(content::WebContents* contents, bool shown);

std::optional<bool> ShownByHost(content::WebContents* contents);

void StartHostVisibility();

// MEM-6: Chrome hides a tab's native view when its window is ordered out (Views' NativeViewHost::HideWidget), which
// is what turns that window's pages hidden: no animation frames, background timer throttling. The app's windows
// aren't Views widgets, so WindowHost does the same through these. `hide` hides a page the host shows (keeping a page
// focus to give back); false shows it again if the host still shows it.
void SetPageHiddenForWindow(content::WebContents* contents, bool hide);
// The host just showed the page's view itself: an earlier window-hidden state no longer applies.
void ClearPageHiddenForWindow(content::WebContents* contents);
void SetPictureInPictureWindowActive(content::WebContents* contents, bool active);

}

#endif

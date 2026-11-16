// Copyright 2026 The Airc Authors
// SPDX-License-Identifier: Apache-2.0

#ifndef AIRC_CORE_AIRC_COLOR_SCHEME_H_
#define AIRC_CORE_AIRC_COLOR_SCHEME_H_

namespace blink::web_pref {
struct WebPreferences;
}
namespace content {
class WebContents;
}

namespace airc {

// A page's preferred colour scheme (`prefers-color-scheme`, `color-scheme: light dark`), as the app decides it from
// the page's Space (Arc: a dark Space's pages are dark). Chrome's own choice follows the browser window's colour mode
// and is otherwise only recomputed after a navigation, so a page kept the scheme it loaded with when macOS switched
// between light and dark. The app sets one per tab; every change reaches the open page at once (its media queries and
// matchMedia change events), and later navigations keep it.
enum class ColorSchemeOverride : int { kNone = 0, kLight = 1, kDark = 2 };

void SetColorSchemeOverride(content::WebContents* contents, ColorSchemeOverride scheme);
ColorSchemeOverride GetColorSchemeOverride(content::WebContents* contents);

// AircContentBrowserClient: applies the tab's override (if any) to `prefs`. Returns whether `prefs` changed.
bool ApplyColorSchemeOverride(content::WebContents* contents, blink::web_pref::WebPreferences* prefs);

}  // namespace airc

#endif  // AIRC_CORE_AIRC_COLOR_SCHEME_H_

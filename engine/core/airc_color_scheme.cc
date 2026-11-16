// Copyright 2026 The Airc Authors
// SPDX-License-Identifier: Apache-2.0

#include "airc/core/airc_color_scheme.h"

#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_user_data.h"
#include "third_party/blink/public/common/web_preferences/web_preferences.h"
#include "third_party/blink/public/mojom/css/preferred_color_scheme.mojom-shared.h"

namespace airc {
namespace {

class ColorSchemeState : public content::WebContentsUserData<ColorSchemeState> {
 public:
  ~ColorSchemeState() override = default;
  ColorSchemeOverride scheme = ColorSchemeOverride::kNone;

 private:
  friend class content::WebContentsUserData<ColorSchemeState>;
  explicit ColorSchemeState(content::WebContents* contents)
      : content::WebContentsUserData<ColorSchemeState>(*contents) {}
  WEB_CONTENTS_USER_DATA_KEY_DECL();
};

WEB_CONTENTS_USER_DATA_KEY_IMPL(ColorSchemeState);

}  // namespace

void SetColorSchemeOverride(content::WebContents* contents, ColorSchemeOverride scheme) {
  if (!contents || GetColorSchemeOverride(contents) == scheme) {
    return;
  }
  ColorSchemeState::CreateForWebContents(contents);
  ColorSchemeState::FromWebContents(contents)->scheme = scheme;
  // Recomputes the preferences (ChromeContentBrowserClient, then ApplyColorSchemeOverride) and sends them to every
  // renderer of the page: media queries re-evaluate and matchMedia listeners fire without a reload.
  contents->NotifyPreferencesChanged();
}

ColorSchemeOverride GetColorSchemeOverride(content::WebContents* contents) {
  auto* state = contents ? ColorSchemeState::FromWebContents(contents) : nullptr;
  return state ? state->scheme : ColorSchemeOverride::kNone;
}

bool ApplyColorSchemeOverride(content::WebContents* contents, blink::web_pref::WebPreferences* prefs) {
  const ColorSchemeOverride scheme = GetColorSchemeOverride(contents);
  if (!prefs || scheme == ColorSchemeOverride::kNone) {
    return false;
  }
  const auto want = scheme == ColorSchemeOverride::kDark ? blink::mojom::PreferredColorScheme::kDark
                                                         : blink::mojom::PreferredColorScheme::kLight;
  const bool changed =
      prefs->preferred_color_scheme != want || prefs->preferred_root_scrollbar_color_scheme != want;
  prefs->preferred_color_scheme = want;
  prefs->preferred_root_scrollbar_color_scheme = want;
  return changed;
}

}  // namespace airc

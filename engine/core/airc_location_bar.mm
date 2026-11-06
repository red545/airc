// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#include "airc/core/airc_browser_window.h"

#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/views/bubble_anchor_util_views.h"
#include "content/public/browser/web_contents.h"
#include "ui/gfx/geometry/rect.h"

namespace airc {

AircLocationBar::AircLocationBar() : LocationBar(nullptr) {}
AircLocationBar::~AircLocationBar() = default;
OmniboxView* AircLocationBar::GetOmniboxView() {
  return nullptr;
}
OmniboxPopupView* AircLocationBar::GetOmniboxPopupView() {
  return nullptr;
}
OmniboxController* AircLocationBar::GetOmniboxController() {
  return nullptr;
}
bool AircLocationBar::ShouldCloseOmniboxPopup(ui::MouseEvent* event) {
  return false;
}
content::WebContents* AircLocationBar::GetWebContents() {
  return browser_ ? browser_->GetTabStripModel()->GetActiveWebContents()
                  : nullptr;
}
LocationBarModel* AircLocationBar::GetLocationBarModel() {
  return nullptr;
}
std::optional<bubble_anchor_util::AnchorConfiguration>
AircLocationBar::GetChipAnchor() {
  return std::nullopt;
}
ChipController* AircLocationBar::GetChipController() {
  return nullptr;
}
ui::TrackedElement* AircLocationBar::GetAnchorOrNull() {
  return nullptr;
}
BrowserWindowInterface* AircLocationBar::GetBrowser() {
  return browser_;
}
Profile* AircLocationBar::GetProfile() {
  return browser_ ? browser_->GetProfile() : nullptr;
}
bool AircLocationBar::IsInitialized() const {
  return true;
}
bool AircLocationBar::IsVisible() const {
  return false;
}
bool AircLocationBar::IsDrawn() const {
  return false;
}
bool AircLocationBar::IsFullscreen() const {
  return false;
}
bool AircLocationBar::IsEditingOrEmpty() const {
  return false;
}
bool AircLocationBar::IsMouseHovered() const {
  return false;
}
bool AircLocationBar::IsFocusWithin() const {
  return false;
}
gfx::Rect AircLocationBar::Bounds() const {
  return gfx::Rect();
}
gfx::Rect AircLocationBar::BoundsInScreen() const {
  return gfx::Rect();
}
gfx::Size AircLocationBar::MinimumSize() const {
  return gfx::Size();
}
gfx::Size AircLocationBar::PreferredSize() const {
  return gfx::Size();
}
bool AircLocationBar::HasSecurityStateChanged() {
  return false;
}
LocationBarTesting* AircLocationBar::GetLocationBarForTesting() {
  return nullptr;
}

}

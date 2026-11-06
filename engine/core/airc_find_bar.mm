// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#include "airc/core/airc_browser_window.h"

#include "chrome/browser/ui/find_bar/find_bar.h"
#include "chrome/browser/ui/find_bar/find_bar_controller.h"
#include "ui/gfx/range/range.h"

namespace airc {

AircFindBar::AircFindBar() = default;
AircFindBar::~AircFindBar() = default;
FindBarController* AircFindBar::GetFindBarController() const {
  return controller_;
}
void AircFindBar::SetFindBarController(FindBarController* controller) {
  controller_ = controller;
}
void AircFindBar::Show(bool animate, bool focus) {
  visible_ = true;
}
void AircFindBar::Hide(bool animate) {
  visible_ = false;
}
void AircFindBar::SetFindTextAndSelectedRange(const std::u16string& find_text,
                                            const gfx::Range& selected_range) {
  find_text_ = find_text;
}
std::u16string_view AircFindBar::GetFindText() const {
  return find_text_;
}
gfx::Range AircFindBar::GetSelectedRange() const {
  return gfx::Range();
}
bool AircFindBar::IsFindBarVisible() const {
  return visible_;
}
bool AircFindBar::HasGlobalFindPasteboard() const {
  return true;
}
bool AircFindBar::CanPopulateFromSelectedText() {
  return true;
}
const FindBarTesting* AircFindBar::GetFindBarTesting() const {
  return nullptr;
}
bool AircFindBar::HasFocus() const {
  return false;
}
views::Widget* AircFindBar::GetHostWidget() {
  return nullptr;
}

}

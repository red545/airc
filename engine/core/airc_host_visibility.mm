// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

// Copyright 2026 Ardia. Apache-2.0.

#include "airc/core/airc_host_visibility.h"
#include "airc/core/airc_memory.h"

#import <AppKit/AppKit.h>

#include "chrome/browser/ui/tabs/public/tab_dialog_manager.h"
#include "chrome/browser/ui/tabs/public/tab_features.h"
#include "components/permissions/permission_request_manager.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_user_data.h"
#include "airc/core/airc_hooks.h"
#include "airc/core/airc_picture_in_picture.h"
#include "airc/core/airc_video_upscaling.h"

namespace airc {

namespace {

class HostVisibility : public content::WebContentsUserData<HostVisibility> {
 public:
  // MEM-6: the view is hidden because its window is ordered out (SetPageHiddenForWindow), with the page's focused
  // view and the window's first responder right after hiding, to give focus back.
  bool hidden_for_window = false;
  __weak NSView* focused_view = nil;
  __weak NSResponder* responder_after_hide = nil;
  bool shown() const { return shown_; }
  void set_shown(bool shown) { shown_ = shown; }

 private:
  explicit HostVisibility(content::WebContents* contents)
      : content::WebContentsUserData<HostVisibility>(*contents) {}
  friend class content::WebContentsUserData<HostVisibility>;
  WEB_CONTENTS_USER_DATA_KEY_DECL();

  bool shown_ = false;
};

WEB_CONTENTS_USER_DATA_KEY_IMPL(HostVisibility);

int Answer(content::WebContents* contents) {
  std::optional<bool> shown = ShownByHost(contents);
  auto* state = contents ? HostVisibility::FromWebContents(contents) : nullptr;
  if (!shown) return -1;
  NSWindow* window = contents->GetNativeView().GetNativeNSView().window;
  return *shown && !state->hidden_for_window &&
      (!window || (window.visible && !window.miniaturized));
}

}

std::optional<bool> ShownByHost(content::WebContents* contents) {
  HostVisibility* state = contents ? HostVisibility::FromWebContents(contents) : nullptr;
  return state ? std::optional<bool>(state->shown()) : std::nullopt;
}

void NoteTabShownByHost(content::WebContents* contents, bool shown) {
  if (!contents || ShownByHost(contents) == shown) {
    return;
  }
  HostVisibility::CreateForWebContents(contents);
  HostVisibility::FromWebContents(contents)->set_shown(shown);
  // AppKit attachment alone does not run Views::WebView's visibility path.
  // Drive WebContents visibility so initial navigations produce compositor frames
  // without requiring a DevTools attachment or a second view reparenting.
  if (shown) contents->WasShown();
  else contents->WasHidden();
  // AppKit may have already hidden the native view (and delivered WasHidden)
  // before the host flag changed. That observer saw the OLD host visibility;
  // a second WasHidden is a no-op. Reschedule against the authoritative flag.
  MemoryHostVisibilityChanged(contents);
  VideoUpscalingInputsChanged();
  TraceAutoPictureInPictureInputs(contents, shown ? "host shows tab" : "host hides tab");
  AircAutoPictureInPictureHostVisibilityChanged(contents);
  if (auto* prompts = permissions::PermissionRequestManager::FromWebContents(contents)) {
    prompts->OnVisibilityChanged(contents->GetVisibility());
  }
  if (auto* tab = tabs::TabInterface::MaybeGetFromContents(contents)) {
    if (auto* features = tab->GetTabFeatures()) {
      if (auto* dialogs = features->tab_dialog_manager()) {
        if (dialogs->UpdateDialogVisibility()) {
          dialogs->UpdateModalDialogBounds();
        }
      }
    }
  }
}

void SetPageHiddenForWindow(content::WebContents* contents, bool hide) {
  HostVisibility* state = contents ? HostVisibility::FromWebContents(contents) : nullptr;
  NSView* view = state ? contents->GetNativeView().GetNativeNSView() : nil;
  if (!view) return;
  NSWindow* window = view.window;
  if (hide) {
    if (!state->shown() || view.hidden || !window) return;
    NSResponder* responder = window.firstResponder;
    const bool focused = [responder isKindOfClass:NSView.class] && [(NSView*)responder isDescendantOf:view];
    state->focused_view = focused ? (NSView*)responder : nil;
    // AppKit would hand a hidden first responder's focus to the next key view (a sidebar field); the window keeps it.
    if (focused) [window makeFirstResponder:nil];
    state->hidden_for_window = true;
    AircAutoPictureInPictureHostVisibilityChanged(contents);
    view.hidden = YES;
    state->responder_after_hide = window.firstResponder;
    return;
  }
  if (!state->hidden_for_window) return;
  state->hidden_for_window = false;
  AircAutoPictureInPictureHostVisibilityChanged(contents);
  NSView* focused = state->focused_view;
  NSResponder* after = state->responder_after_hide;
  state->focused_view = nil;
  state->responder_after_hide = nil;
  if (!state->shown() || !view.hidden) return;
  view.hidden = NO;
  // Give the page its focus back unless something else took it meanwhile.
  if (focused && window && [focused isDescendantOf:view] && window.firstResponder == after) {
    [window makeFirstResponder:focused];
  }
}

void ClearPageHiddenForWindow(content::WebContents* contents) {
  if (HostVisibility* state = contents ? HostVisibility::FromWebContents(contents) : nullptr) {
    state->hidden_for_window = false;
    state->focused_view = nil;
    state->responder_after_hide = nil;
  }
}

void SetPictureInPictureWindowActive(content::WebContents* contents, bool active) {
  if (!contents) return;
  HostVisibility::CreateForWebContents(contents);
  // Key-window loss is not visibility loss (Notification Center, Spotlight,
  // menu extras and other system overlays). Reevaluate actual attachment/window
  // visibility only. An app switch alone is not an off-screen signal either.
  AircAutoPictureInPictureHostVisibilityChanged(contents);
}

void StartHostVisibility() {
  g_airc_tab_shown_by_host = &Answer;
  g_airc_permission_tab_shown = [](content::WebContents* contents) {
    auto shown = ShownByHost(contents);
    return shown ? static_cast<int>(*shown) : -1;
  };
}

}

// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#include "airc/core/airc_browser.h"

#import <AppKit/AppKit.h>

#include "base/auto_reset.h"
#include "base/functional/bind.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "chrome/browser/lifetime/browser_shutdown.h"
#include "chrome/browser/tab_list/tab_removed_reason.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/passwords/passwords_model_delegate.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/unload_controller.h"
#include "components/password_manager/core/browser/password_form.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/web_contents.h"
#include "airc/core/airc_autofill_trigger.h"
#include "airc/core/airc_browser_internal.h"
#include "airc/core/airc_browser_window.h"
#include "airc/core/airc_modal_dialog_host.h"
#include "airc/core/airc_installed_bubble.h"
#include "airc/core/airc_password_prompt.h"
#include "airc/core/airc_video_upscaling.h"
#import "airc/core/airc_internal.h"
#include "url/origin.h"

namespace airc {

void WindowHost::ActiveTabChanged(Browser* browser,
                                  content::WebContents* contents) {
  if (!contents) {
    return;
  }
  VideoUpscalingInputsChanged();
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&ShowWaitingInstalledBubbles));
  ScopedNotifying notifying(ScopedNotifying::Kind::kTabStrip);
  AircTab* tab = TabBridge::GetOrCreate(contents)->tab();
  AircWindow* owner = owner_;
  if ([owner.delegate respondsToSelector:@selector(window:didActivateTab:)]) {
    [owner.delegate window:owner didActivateTab:tab];
  }
}

void WindowHost::TabStripEmpty() {
  if (closing() || browser_shutdown::IsTryingToQuit()) return;
  // Browser::TabStripEmpty is suppressed for our retained profile Browsers,
  // but UnloadController also observes the empty strip and enters
  // kUnloadCompleted. Leaving it there lets a later renderer exit (including
  // discard) resume ProcessPendingTabs and close every newly opened tab.
  // We register after Chromium's observers, so cancel that completed, uncommitted
  // close here, before any new tabs or renderer notifications can arrive.
  for (Browser* browser : browsers()) {
    auto* window = AircBrowserWindow::FromWindow(BrowserWindow::FromBrowser(browser));
    auto* unload = UnloadController::From(browser);
    if (browser->GetTabStripModel()->empty() && window &&
        !window->closed_by_chrome() && !unload->is_delete_scheduled() &&
        unload->is_attempting_to_close_browser()) {
      NSLog(@"Airc: retaining empty profile Browser; cancelling strip-empty unload state");
      unload->CancelWindowClose();
    }
  }
}

void WindowHost::OnTabStripModelChanged(
    TabStripModel* tab_strip_model,
    const TabStripModelChange& change,
    const TabStripSelectionChange& selection) {
  ScopedNotifying notifying(ScopedNotifying::Kind::kTabStrip);
  AircWindow* owner = owner_;
  id<AircWindowDelegate> delegate = owner.delegate;
  if (change.type() == TabStripModelChange::kInserted) {
    for (const auto& inserted : change.GetInsert()->contents) {
      TabBridge* bridge = TabBridge::GetOrCreate(inserted.contents);
      TrackAutofillFocus(inserted.contents);
      bridge->EnsureFaviconObserved();
      bridge->EnsurePopupsObserved();
      bridge->EnsureZoomObserved();
      std::optional<WindowOpenDisposition> disposition =
          bridge->TakeOpenDisposition();
      content::WebContents* source = bridge->open_source();
      if (!disposition && pending_open_.disposition) {
        disposition = pending_open_.disposition;
        source = pending_open_.source.get();
        bridge->set_open(pending_open_);
      }
      if (!source) {
        tabs::TabInterface* opener_tab =
            tab_strip_model->GetOpenerOfTabAt(inserted.index);
        source = opener_tab ? opener_tab->GetContents() : nullptr;
      }
      AircTab* opener =
          source ? TabBridge::GetOrCreate(source)->tab() : nil;
      if (!disposition) {
        disposition = tab_strip_model->active_index() == inserted.index
                          ? WindowOpenDisposition::NEW_FOREGROUND_TAB
                          : WindowOpenDisposition::NEW_BACKGROUND_TAB;
      }
      if (!host_open_ && [delegate respondsToSelector:@selector
                    (window:didInsertTab:opener:disposition:)]) {
        [delegate window:owner
            didInsertTab:bridge->tab()
                  opener:opener
             disposition:@(DispositionName(*disposition))];
      }
    }
  } else if (change.type() == TabStripModelChange::kRemoved) {
    for (const auto& removed : change.GetRemove()->contents) {
      if (!removed.contents) {
        continue;
      }
      // User-data destruction is too late: LoginTabHelper cancellation still
      // needs the NavigationController's visible entry. Close synchronously
      // while removal notification guarantees the WebContents is intact.
      if (removed.remove_reason == TabRemovedReason::kDeleted) {
        if (auto* dialogs = AircTabDialogHost::FromWebContents(removed.contents))
          dialogs->CloseDialogs();
      }
      TabBridge* bridge = TabBridge::FromWebContents(removed.contents);
      Browser* browser = nullptr;
      for (Browser* b : browsers()) {
        if (b->GetTabStripModel() == tab_strip_model) {
          browser = b;
        }
      }
      AircBrowserWindow* browser_window =
          browser ? AircBrowserWindow::FromWindow(BrowserWindow::FromBrowser(browser)) : nullptr;
      const bool browser_closing =
          !browser ||
          (UnloadController::From(browser)->is_attempting_to_close_browser() &&
           !(browser_window && browser_window->closed_by_chrome()));
      if (bridge && removed.remove_reason == TabRemovedReason::kDeleted &&
          !browser_closing && !closing() && !browser_shutdown::IsTryingToQuit()) {
        bridge->ReportWillClose();
      }
      if (bridge &&
          [delegate respondsToSelector:@selector(window:didRemoveTab:)]) {
        [delegate window:owner didRemoveTab:bridge->tab()];
      }
    }
  }
}

void WindowHost::DevToolsDockChanged(content::WebContents* inspected,
                                     content::WebContents* devtools) {
  AircWindow* owner = owner_;
  id<AircWindowDelegate> delegate = owner.delegate;
  if (![delegate respondsToSelector:@selector(window:
                                        devToolsDidChangeForTab:view:)]) {
    return;
  }
  NSView* view =
      devtools ? devtools->GetNativeView().GetNativeNSView() : nil;
  [delegate window:owner
      devToolsDidChangeForTab:TabBridge::GetOrCreate(inspected)->tab()
                         view:view];
}

bool WindowHost::OfferPasswordSave(content::WebContents* contents) {
  AircWindow* owner = owner_;
  id<AircWindowDelegate> delegate = owner.delegate;
  if ([delegate respondsToSelector:@selector(window:passwordPrompt:forTab:)]) {
    NSDictionary* prompt = PasswordPrompt(contents);
    if (!prompt) {
      return false;
    }
    PasswordPromptShown(contents);
    [delegate window:owner
        passwordPrompt:prompt
                forTab:TabBridge::GetOrCreate(contents)->tab()];
    PasswordConfirmationShown(contents);
    return true;
  }
  if (![delegate respondsToSelector:@selector
                 (window:passwordSavePromptForTab:username:origin:)]) {
    return false;
  }
  base::WeakPtr<PasswordsModelDelegate> model =
      PasswordsModelDelegateFromWebContents(contents);
  if (!model ||
      model->GetState() != password_manager::ui::PENDING_PASSWORD_STATE) {
    return false;
  }
  const password_manager::PasswordForm& form = model->GetPendingPassword();
  [delegate window:owner
      passwordSavePromptForTab:TabBridge::GetOrCreate(contents)->tab()
                      username:base::SysUTF16ToNSString(form.username_value)
                        origin:base::SysUTF8ToNSString(
                                   model->GetOrigin().Serialize())];
  return true;
}

void WindowHost::FullscreenChanged(content::WebContents* contents,
                                   bool fullscreen) {
  AircWindow* owner = owner_;
  id<AircWindowDelegate> delegate = owner.delegate;
  if (contents && [delegate respondsToSelector:@selector
                            (window:tab:didChangeFullscreen:)]) {
    [delegate window:owner
                     tab:TabBridge::GetOrCreate(contents)->tab()
        didChangeFullscreen:fullscreen];
  }
}

}

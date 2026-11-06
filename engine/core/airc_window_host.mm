// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#include "airc/core/airc_browser.h"

#import <AppKit/AppKit.h>

#include "base/functional/bind.h"
#include "base/no_destructor.h"
#include "base/task/single_thread_task_runner.h"
#include "chrome/browser/lifetime/browser_shutdown.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/keep_alive/scoped_profile_keep_alive.h"
#include "chrome/browser/profiles/keep_alive/profile_keep_alive_types.h"
#include "chrome/browser/ui/unload_controller.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/browser_active_state_manager/browser_active_state_manager.h"
#include "chrome/browser/ui/browser_window/public/create_browser_window.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/views/interaction/browser_elements_views_impl.h"
#import "components/remote_cocoa/app_shim/bridged_content_view.h"
#include "content/public/browser/web_contents.h"
#include "airc/core/airc_browser_internal.h"
#include "airc/core/airc_browser_window.h"
#include "airc/core/airc_extension_shortcuts.h"
#include "airc/core/airc_host_visibility.h"
#include "airc/core/airc_modal_dialog_host.h"
#include "airc/core/airc_video_upscaling.h"
#import "airc/core/airc_internal.h"
#include "ui/views/widget/widget.h"
#include "ui/views/widget/widget_delegate.h"
#include "ui/views/window/client_view.h"

namespace airc {

std::vector<WindowHost*>& Hosts() {
  static base::NoDestructor<std::vector<WindowHost*>> hosts;
  return *hosts;
}

namespace {

class HostClientView : public views::ClientView {
 public:
  HostClientView(views::Widget* widget,
                 views::View* contents,
                 base::WeakPtr<WindowHost> host)
      : views::ClientView(widget, contents), host_(std::move(host)) {}

  views::CloseRequestResult OnWindowCloseRequested() override {
    if (!host_ || host_->CanCloseWidget()) {
      return views::CloseRequestResult::kCanClose;
    }
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&WindowHost::CloseRequestedByUser, host_));
    return views::CloseRequestResult::kCannotClose;
  }

 private:
  base::WeakPtr<WindowHost> host_;
};

}

const std::vector<WindowHost*>& WindowHost::All() {
  return Hosts();
}

WindowHost* WindowHost::ForNSWindow(NSWindow* window) {
  for (WindowHost* host : Hosts()) {
    if (window && host->ns_window() == window) {
      return host;
    }
  }
  return nullptr;
}

WindowHost* WindowHost::ForBrowser(const BrowserWindowInterface* browser) {
  return AircBrowserWindow::HostOf(browser);
}

WindowHost* WindowHost::ForContents(content::WebContents* contents) {
  return contents ? ForBrowser(GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(
                        contents))
                  : nullptr;
}

WindowHost::WindowHost(AircWindow* owner, const gfx::Rect& bounds)
    : owner_(owner), owner_ref_(owner) {
  Hosts().push_back(this);
  widget_delegate_ = std::make_unique<views::WidgetDelegate>();
  widget_delegate_->SetCanResize(true);
  widget_delegate_->SetCanMaximize(true);
  widget_delegate_->SetCanMinimize(true);
  widget_delegate_->SetTitle(u"Airc");
  widget_delegate_->SetClientViewFactory(base::BindOnce(
      [](base::WeakPtr<WindowHost> host, views::Widget* widget,
         views::View* contents) -> std::unique_ptr<views::ClientView> {
        return std::make_unique<HostClientView>(widget, contents, host);
      },
      GetWeakPtr()));

  widget_ = std::make_unique<views::Widget>();
  views::Widget::InitParams params(
      views::Widget::InitParams::CLIENT_OWNS_WIDGET,
      views::Widget::InitParams::TYPE_WINDOW);
  params.delegate = widget_delegate_.get();
  params.bounds = bounds;
  params.name = "AircWindow";
  widget_->Init(std::move(params));
  widget_->AddObserver(this);

  NSWindow* window = ns_window();
  NSView* content = window.contentView;
  host_view_ = [[NSView alloc] initWithFrame:content.bounds];
  host_view_.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [content addSubview:host_view_];
  InstallExtensionShortcutDispatcher(window);
}

// Retain internal scaffolding, but bind BrowserElementsViews to the registered
// modal parent in AddBrowser. Page NSViews keep their own compositor and remain
// in the app's responder chain; no BridgedContentView is moved into that chain.
WindowHost::WindowHost(AircWindow* owner, NSWindow* window, NSView* host_view)
    : WindowHost(owner, gfx::Rect(0, 0, 640, 480)) {
  [host_view_ removeFromSuperview];
  external_window_ = window;
  host_view_ = host_view;
  host_view_.postsFrameChangedNotifications = YES;
  window_observers_ = [NSMutableArray array];
  auto weak = GetWeakPtr();
  for (NSNotificationName name in @[NSWindowDidBecomeKeyNotification,
                                    NSWindowDidResignKeyNotification,
                                    NSWindowDidMiniaturizeNotification,
                                    NSWindowDidDeminiaturizeNotification,
                                    NSWindowDidResizeNotification,
                                    NSWindowDidMoveNotification]) {
    id token = [NSNotificationCenter.defaultCenter addObserverForName:name
        object:window queue:nil usingBlock:^(NSNotification* note) {
      if (!weak) return;
      if ([note.name isEqualToString:NSWindowDidBecomeKeyNotification] ||
          [note.name isEqualToString:NSWindowDidResignKeyNotification]) {
        weak->OnWidgetActivationChanged(nullptr, weak->ns_window().isKeyWindow);
      }
      weak->UpdatePagesForWindowVisibility();
      weak->ScheduleDialogPositionUpdate();
    }];
    [window_observers_ addObject:token];
  }
  // MEM-6: ordered out or back in (⌘H, closed while its pages live on, the app launched hidden…) → its pages.
  [window_observers_ addObject:[NSNotificationCenter.defaultCenter
      addObserverForName:NSWindowDidChangeOcclusionStateNotification
                  object:window
                   queue:nil
              usingBlock:^(NSNotification*) {
                if (weak) weak->UpdatePagesForWindowVisibility();
              }]];
  for (NSNotificationName name in @[NSApplicationDidHideNotification, NSApplicationDidUnhideNotification]) {
    [window_observers_ addObject:[NSNotificationCenter.defaultCenter
        addObserverForName:name
                    object:NSApp
                     queue:nil
                usingBlock:^(NSNotification*) {
                  if (weak) weak->UpdatePagesForWindowVisibility();
                }]];
  }
  // A dialog can be created or change sheets while the app is on another
  // Space (including after TCC). Defer its native parent until this window's
  // Space returns; no key-window event is guaranteed for ShowInactive hosts.
  workspace_observer_ = [NSWorkspace.sharedWorkspace.notificationCenter
      addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification
                  object:nil queue:nil usingBlock:^(NSNotification*) {
        if (weak && weak->modal_parent_) weak->ScheduleDialogPositionUpdate();
      }];
  // First layout (and later moves within the window) re-anchor the modal parent.
  [window_observers_ addObject:[NSNotificationCenter.defaultCenter
      addObserverForName:NSViewFrameDidChangeNotification
                  object:host_view
                   queue:nil
              usingBlock:^(NSNotification*) {
                if (weak && weak->modal_parent_) weak->ScheduleDialogPositionUpdate();
              }]];
}

WindowHost::~WindowHost() {
  if (workspace_observer_)
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:workspace_observer_];
  for (id token in window_observers_) {
    [NSNotificationCenter.defaultCenter removeObserver:token];
  }
  std::erase(Hosts(), this);
  for (auto& observer : modal_observers_) {
    observer.OnHostDestroying();
  }
  for ([[maybe_unused]] auto& observer : modal_observers_) {
    DialogHostObserverRemoved();
  }
  for (auto& [profile, browser] : browsers_) {
    browser->GetTabStripModel()->RemoveObserver(this);
    if (auto* elements = BrowserElementsViews::From(browser)) {
      elements->TearDown();
    }
  }
  browsers_.clear();
  widget_close_allowed_ = true;
  if (widget_) {
    widget_->RemoveObserver(this);
  }
  modal_parent_.reset();
  widget_.reset();
}

namespace {

void ActivateExclusively(Browser* browser) {
  if (browser->IsDeleteScheduled()) {
    return;
  }
  for (WindowHost* host : WindowHost::All()) {
    for (Browser* other : host->browsers()) {
      if (other != browser) {
        BrowserActiveStateManager::From(other)->DidBecomeInactive();
      }
    }
  }
  BrowserActiveStateManager* state = BrowserActiveStateManager::From(browser);
  if (GlobalBrowserCollection::GetInstance()->GetLastActiveBrowser() != browser ||
      ProfileManager::GetLastUsedProfileIfLoaded() != browser->GetProfile()) {
    state->DidBecomeInactive();
  }
  state->DidBecomeActive();
}

base::WeakPtr<WindowHost>& LastUsersWindow() {
  static base::NoDestructor<base::WeakPtr<WindowHost>> host;
  return *host;
}

}

bool WindowHost::IsUsersWindow() {
  if (internal_ || !widget_) {
    return false;
  }
  if (ns_window().isKeyWindow) {
    return true;
  }
  for (WindowHost* host : Hosts()) {
    if (host->ns_window().isKeyWindow) {
      return false;
    }
  }
  if (!LastUsersWindow()) {
    LastUsersWindow() = GetWeakPtr();
  }
  return LastUsersWindow().get() == this;
}

void WindowHost::NoteHostActivated(Browser* browser) {
  if (!IsActiveBrowser(browser) || !IsUsersWindow()) {
    return;
  }
  if (GlobalBrowserCollection::GetInstance()->GetLastActiveBrowser() == browser &&
      ProfileManager::GetLastUsedProfileIfLoaded() == browser->GetProfile()) {
    return;
  }
  ActivateExclusively(browser);
}

void WindowHost::RequestActivation(Browser* browser) {
  if (internal_ || !widget_ || !ns_window().isVisible ||
      ExistingBrowserFor(browser->GetProfile()) != browser) {
    return;
  }
  if (!NSApp.isActive) {
    return;
  }
  if (IsActiveBrowser(browser)) {
    [ns_window() makeKeyAndOrderFront:nil];
    return;
  }
  content::WebContents* contents = browser->GetTabStripModel()->GetActiveWebContents();
  AircTab* tab = contents ? TabBridge::GetOrCreate(contents)->tab() : nil;
  id<AircTabDelegate> delegate = tab.delegate;
  if ([delegate respondsToSelector:@selector(tab:requestsActivation:)]) {
    [delegate tab:tab requestsActivation:@"window"];
  }
}

void WindowHost::OnWidgetActivationChanged(views::Widget* widget, bool active) {
  if (active && !internal_) {
    LastUsersWindow() = GetWeakPtr();
  }
  Browser* browser = !internal_ && active_profile_ ? ExistingBrowserFor(active_profile_) : nullptr;
  if (!browser) {
    return;
  }
  if (active) {
    ActivateExclusively(browser);
  } else {
    BrowserActiveStateManager::From(browser)->DidBecomeInactive();
  }
}

// A minimized window keeps its pages for Chromium's occlusion checker (occluded, as in Chrome); so does a window that
// is only covered. Only an ordered-out one hides them.
void WindowHost::UpdatePagesForWindowVisibility() {
  window_visibility_check_scheduled_ = false;
  if (!external_window_ || closing()) return;
  NSWindow* window = ns_window();
  const bool hide = !window.isVisible && !window.isMiniaturized;
  pages_hidden_for_window_ = hide;
  // A full call window can host a page while its Browser remains in the
  // original window. Visibility belongs to the actual native parent, not the
  // tab-strip owner. Also find pages hosted here from another WindowHost.
  for (WindowHost* owner : Hosts()) {
    for (const auto& [profile, browser] : owner->browsers_) {
      TabStripModel* tabs = browser->GetTabStripModel();
      for (int i = 0; i < tabs->count(); ++i) {
        auto* contents = tabs->GetWebContentsAt(i);
        NSView* view = contents->GetNativeView().GetNativeNSView();
        if (view.window == window) {
          SetPageHiddenForWindow(contents, hide);
          SetPictureInPictureWindowActive(contents, window.isKeyWindow);
        }
      }
    }
  }
}

void WindowHost::PageShownByHost(content::WebContents* contents) {
  if (!external_window_) return;
  ClearPageHiddenForWindow(contents);
  if (pages_hidden_for_window_) {
    SetPageHiddenForWindow(contents, true);
  } else if (!ns_window().isVisible && NSApp.isHidden) {
    // The app is hidden (⌘H, or launched hidden): its windows stay off screen until it's unhidden, which this hears.
    UpdatePagesForWindowVisibility();
  } else if (!ns_window().isVisible && !window_visibility_check_scheduled_) {
    // Not on screen yet (a page attached before the window is shown) or just ordered out: decide once that has
    // settled, as Chromium's occlusion checker waits a second before backgrounding.
    window_visibility_check_scheduled_ = true;
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
        FROM_HERE, base::BindOnce(&WindowHost::UpdatePagesForWindowVisibility, GetWeakPtr()),
        base::Seconds(1));
  }
}

NSWindow* WindowHost::ns_window() const {
  return external_window_ ?: (widget_ ? widget_->GetNativeWindow().GetNativeNSWindow() : nil);
}

Browser* WindowHost::ExistingBrowserFor(Profile* profile) const {
  auto it = browsers_.find(profile);
  return it == browsers_.end() ? nullptr : it->second.get();
}

std::vector<Browser*> WindowHost::browsers() const {
  std::vector<Browser*> list;
  for (const auto& [profile, browser] : browsers_) {
    list.push_back(browser.get());
  }
  return list;
}

Browser* WindowHost::BrowserFor(Profile* profile) {
  if (!profile || IsProfileDying(profile)) {
    return nullptr;
  }
  if (Browser* browser = ExistingBrowserFor(profile)) {
    if (!UnloadController::From(browser)->is_delete_scheduled()) return browser;
    // Its asynchronous deletion is already queued. Stop routing new tabs to it;
    // BrowserWindowDestroyed checks identity and cannot erase its replacement.
    browser->GetTabStripModel()->RemoveObserver(this);
    browsers_.erase(profile);
    NSLog(@"Airc: replacing profile Browser already scheduled for deletion");
  }
  if (IsProfileDeleting(profile)) {
    return nullptr;
  }
  if (close_state_ != CloseState::kOpen || !widget_ || widget_close_allowed_ ||
      browser_shutdown::IsTryingToQuit() ||
      GetBrowserWindowCreationStatusForProfile(*profile) !=
          BrowserWindowInterface::CreationStatus::kOk) {
    return nullptr;
  }
  if (profile_keep_alives_.contains(profile)) {
    NSLog(@"Airc: recovering missing profile Browser for open/prepare");
  } else if (!profile->IsOffTheRecord()) {
    auto keep_alive = ScopedProfileKeepAlive::TryAcquire(profile, ProfileKeepAliveOrigin::kBrowserWindow);
    if (!keep_alive) return nullptr;
    profile_keep_alives_.emplace(profile, std::move(keep_alive));
  }
  auto* window = new AircBrowserWindow(GetWeakPtr());
  BrowserWindowCreateParams params(BrowserWindowInterface::TYPE_NORMAL,
                                   *profile, true);
  params.window = window;
  params.omit_from_session_restore = true;
  params.should_trigger_session_restore = false;
  Browser* browser = static_cast<Browser*>(CreateBrowserWindow(std::move(params)));
  window->AttachBrowser(browser);
  AddBrowser(browser);
  return browser;
}

BrowserWindow* WindowHost::HostChromeBrowser(Browser* browser) {
  Profile* profile = browser->GetProfile();
  if (AircBrowserWindow::IsOurs(browser) || close_state_ != CloseState::kOpen ||
      widget_close_allowed_ || ExistingBrowserFor(profile)) {
    return nullptr;
  }
  auto* window = new AircBrowserWindow(GetWeakPtr());
  window->AttachBrowser(browser);
  AddBrowser(browser);
  return window;
}

void WindowHost::AddBrowser(Browser* browser) {
  Profile* profile = browser->GetProfile();
  browsers_[profile] = browser;
  if (auto* elements = BrowserElements::From(browser)) {
    if (auto* views_elements = elements->AsA<BrowserElementsViewsImpl>()) {
      if (externally_hosted()) UpdateModalParent();
      views_elements->Init((modal_parent_ ? modal_parent_.get() : widget_.get())
                               ->GetRootView());
    }
  }
  browser->GetTabStripModel()->AddObserver(this);
  if (!active_profile_) {
    SetActiveProfile(profile);
  }
}

void WindowHost::SetActiveProfile(Profile* profile) {
  if (active_profile_ == profile) {
    return;
  }
  Browser* old_browser =
      active_profile_ ? ExistingBrowserFor(active_profile_) : nullptr;
  active_profile_ = profile;
  VideoUpscalingInputsChanged();
  if (old_browser) {
    BrowserActiveStateManager::From(old_browser)->DidBecomeInactive();
  }
  if (Browser* browser = ExistingBrowserFor(profile)) {
    NoteHostActivated(browser);
  }
}

bool WindowHost::IsActiveBrowser(const Browser* browser) const {
  return browser && active_profile_ &&
         ExistingBrowserFor(active_profile_) == browser;
}

void WindowHost::ShowInactive() {
  if (external_window_) {
    if (!widget_close_allowed_) [external_window_ orderFront:nil];
    if (modal_parent_) UpdateModalParent();
    return;
  }
  if (widget_ && !widget_close_allowed_ && !widget_->IsVisible()) {
    widget_->ShowInactive();
  }
}

}

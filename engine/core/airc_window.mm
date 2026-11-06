// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#import "airc/core/public/Airc.h"

#include <algorithm>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "base/auto_reset.h"
#include "base/base64.h"
#include "base/pickle.h"
#include "base/strings/sys_string_conversions.h"
#include "base/time/time.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/browser_commands.h"
#include "chrome/browser/ui/browser_tabrestore.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/navigator/browser_navigator.h"
#include "chrome/browser/ui/navigator/browser_navigator_params.h"
#include "chrome/browser/ui/tabs/tab_enums.h"
#include "chrome/browser/ui/tabs/tab_model.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#import "components/remote_cocoa/app_shim/bridged_content_view.h"
#import "components/remote_cocoa/app_shim/native_widget_mac_frameless_nswindow.h"
#include "components/sessions/core/serialized_navigation_entry.h"
#include "components/sessions/core/serialized_user_agent_override.h"
#include "content/public/browser/web_contents.h"
#include "ui/base/window_open_disposition.h"
#include "ui/gfx/mac/coordinate_conversion.h"
#include "url/gurl.h"
#include "airc/core/airc_browser.h"
#include "airc/core/airc_contents_background.h"
#include "airc/core/airc_extension_view.h"
#include "airc/core/airc_host_visibility.h"
#import "airc/core/airc_internal.h"

@interface BridgedContentView (AircEmbedded)
- (NSView*)aircEmbeddedSubview;
@end

@implementation AircWindow {
  std::unique_ptr<airc::WindowHost> _host;
}

+ (NSView*)embeddedRootOfWindow:(NSWindow*)window {
  airc::WindowHost* host = airc::WindowHost::ForNSWindow(window);
  return host ? host->host_view() : nil;
}

+ (Class)contentViewClass {
  return [BridgedContentView class];
}

+ (BOOL)isChromeFramelessWindow:(NSWindow*)window {
  return [window isKindOfClass:[NativeWidgetMacFramelessNSWindow class]];
}

@synthesize delegate = _delegate;

- (instancetype)initWithContentRect:(NSRect)rect {
  if ((self = [super init])) {
    _host = std::make_unique<airc::WindowHost>(self,
                                                 gfx::ScreenRectFromNSRect(rect));
  }
  return self;
}

- (instancetype)initWithWindow:(NSWindow*)window hostView:(NSView*)hostView {
  NSParameterAssert(NSThread.isMainThread);
  NSParameterAssert(window);
  NSParameterAssert(hostView);
  if ((self = [super init])) {
    _host = std::make_unique<airc::WindowHost>(self, window, hostView);
  }
  return self;
}

- (airc::WindowHost*)host {
  return _host.get();
}

- (NSWindow*)window {
  return _host->ns_window();
}

- (NSView*)hostView {
  return _host->host_view();
}

- (AircTab*)openTab:(NSString*)url
              profile:(AircProfile*)profile
           foreground:(BOOL)foreground {
  Browser* browser = _host->BrowserFor(profile.chromeProfile);
  if (!browser) {
    NSLog(@"Airc: cannot open tab: profile unavailable or host is closing");
    return nil;
  }
  const bool ahead = !url.length;
  NavigateParams params(browser, GURL(ahead ? "about:blank" : base::SysNSStringToUTF8(url)),
                        ui::PAGE_TRANSITION_TYPED);
  params.disposition = foreground ? WindowOpenDisposition::NEW_FOREGROUND_TAB
                                  : WindowOpenDisposition::NEW_BACKGROUND_TAB;
  params.window_action = NavigateParams::WindowAction::kNoAction;
  auto pending = _host->ScopedPendingOpen({params.disposition, nullptr});
  auto host_open = _host->ScopedHostOpen();
  Navigate(&params);
  content::WebContents* contents = params.navigated_or_inserted_contents;
  if (!contents) {
    NSLog(@"Airc: Navigate did not create tab contents for prepared Browser");
    return nil;
  }
  airc::TabBridge* bridge = airc::TabBridge::GetOrCreate(contents);
  if (ahead) {
    bridge->set_made_ahead();
    airc::MarkAheadBlank(contents);
  }
  // MEM-6: a background tab is hidden until the host shows it. The first tab of a profile's Browser (its tab strip's
  // active tab) was found visible though never shown: pages nobody could see drew every frame (two of the perf
  // workload's thirty, ~4% of a core each plus the GPU's).
  if (!foreground) {
    airc::NoteTabShownByHost(contents, false);
  }
  return bridge->tab();
}

- (AircTab*)openExtensionView:(NSString*)url
                        profile:(AircProfile*)profile
                           kind:(NSString*)kind {
  content::WebContents* contents = airc::OpenExtensionView(
      _host->BrowserFor(profile.chromeProfile), GURL(base::SysNSStringToUTF8(url)),
      [kind isEqualToString:@"sidePanel"] ? airc::ExtensionViewKind::kSidePanel
                                          : airc::ExtensionViewKind::kPopup);
  return contents ? airc::TabBridge::GetOrCreate(contents)->tab() : nil;
}

- (AircProfile*)activeProfile {
  Profile* profile = _host->active_profile();
  return profile ? [AircProfile wrapperFor:profile] : nil;
}

- (void)setActiveProfile:(AircProfile*)profile {
  if (profile.chromeProfile) _host->BrowserFor(profile.chromeProfile);
  _host->SetActiveProfile(profile.chromeProfile);
}

- (void)activateTab:(AircTab*)tab {
  [self closeActionPopup];
  if (airc::DeferWhileTabStripNotifies(^{
        [self activateTab:tab];
      })) {
    return;
  }
  content::WebContents* contents = tab.contents;
  if (!contents) {
    return;
  }
  BrowserWindowInterface* browser =
      GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(contents);
  if (!browser) {
    return;
  }
  auto focusing = airc::TabBridge::GetOrCreate(contents)->HostFocuses();
  if (airc::WindowHost::ForBrowser(browser) != _host.get()) return;
  _host->SetActiveProfile(browser->GetProfile());
  _host->NoteHostActivated(static_cast<Browser*>(browser));
  TabStripModel* model = browser->GetTabStripModel();
  int index = model->GetIndexOfWebContents(contents);
  if (index != TabStripModel::kNoTab && index != model->active_index()) {
    model->ActivateTabAt(index);
  }
}

- (NSArray<AircTab*>*)tabsForProfile:(AircProfile*)profile {
  NSMutableArray* tabs = [NSMutableArray array];
  Browser* browser = _host->ExistingBrowserFor(profile.chromeProfile);
  if (!browser) {
    return tabs;
  }
  TabStripModel* model = browser->GetTabStripModel();
  for (int i = 0; i < model->count(); ++i) {
    [tabs addObject:airc::TabBridge::GetOrCreate(model->GetWebContentsAt(i))
                        ->tab()];
  }
  return tabs;
}

- (int)chromeWindowIdForProfile:(AircProfile*)profile {
  Browser* browser = _host->ExistingBrowserFor(profile.chromeProfile);
  return browser ? browser->GetSessionID().id() : -1;
}

- (BOOL)executeChromeCommand:(int)commandId profile:(AircProfile*)profile {
  Browser* browser = _host->ExistingBrowserFor(profile.chromeProfile);
  return browser && chrome::ExecuteCommand(browser, commandId);
}

- (BOOL)internal {
  return _host->internal();
}

- (void)setInternal:(BOOL)internal {
  _host->set_internal(internal);
}

- (void)showInactive {
  _host->ShowInactive();
}

- (BOOL)actedFullScreen {
  return _host->acted_fullscreen();
}

- (void)setActedFullScreen:(BOOL)acted {
  _host->set_acted_fullscreen(acted);
}

- (void)adoptTab:(AircTab*)tab {
  if (airc::DeferWhileTabStripNotifies(^{
        [self adoptTab:tab];
      })) {
    return;
  }
  content::WebContents* contents = tab.contents;
  if (!contents) {
    return;
  }
  BrowserWindowInterface* from =
      GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(contents);
  Browser* to = _host->BrowserFor(
      Profile::FromBrowserContext(contents->GetBrowserContext()));
  if (!from || !to || from == to) {
    return;
  }
  TabStripModel* source = from->GetTabStripModel();
  const int index = source->GetIndexOfWebContents(contents);
  if (index == TabStripModel::kNoTab) {
    return;
  }
  std::unique_ptr<tabs::TabModel> moved = source->DetachTabAtForInsertion(index);
  if (!moved) {
    return;
  }
  TabStripModel* target = to->GetTabStripModel();
  target->InsertDetachedTabAt(target->count(), std::move(moved),
                              AddTabTypes::ADD_NONE);
}

- (NSString*)moveTab:(AircTab*)tab profile:(AircProfile*)profile toView:(NSView*)view {
  NSParameterAssert(NSThread.isMainThread);
  if (tab.closed || !tab.contents) return @"closedTab";
  if (!profile.chromeProfile || tab.profile.chromeProfile != profile.chromeProfile)
    return @"profileMismatch";
  if (view.window != self.window || view == tab.view || [view isDescendantOf:tab.view])
    return @"invalidHost";
  if (airc::IsNotifyingTabStrip()) return @"busy";
  if (_host->closing()) return @"closingWindow";
  auto* from = GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(tab.contents);
  auto* source_host = from ? airc::WindowHost::ForBrowser(from) : nullptr;
  if (!source_host) return @"missingOwner";
  if (source_host->closing()) return @"closingWindow";
  // Do not send a hide/show pair: that would spuriously trigger automatic PiP.
  NSView* page = tab.view;
  BOOL focused = [page.window.firstResponder isKindOfClass:NSView.class] &&
      [(NSView*)page.window.firstResponder isDescendantOf:page];
  if (focused) [page.window makeFirstResponder:nil];
  auto host_open = _host->ScopedHostOpen();
  [self adoptTab:tab];
  [tab attachToView:view];
  if (focused) { [self activateTab:tab]; [tab focus]; }
  return nil;
}

- (AircTab*)openPeek:(NSString*)url opener:(AircTab*)opener inView:(NSView*)view {
  if (opener.closed || !opener.profile || view.window != self.window) return nil;
  AircTab* tab = [self openTab:url profile:opener.profile foreground:NO];
  [tab attachToView:view];
  return tab;
}

- (void)placeTab:(AircTab*)tab index:(int)index pinned:(BOOL)pinned {
  if (airc::DeferWhileTabStripNotifies(^{
        [self placeTab:tab index:index pinned:pinned];
      })) {
    return;
  }
  content::WebContents* contents = tab.contents;
  if (!contents) {
    return;
  }
  BrowserWindowInterface* browser =
      GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(contents);
  if (!browser || airc::WindowHost::ForBrowser(browser) != _host.get()) {
    return;
  }
  TabStripModel* model = browser->GetTabStripModel();
  int at = model->GetIndexOfWebContents(contents);
  if (at == TabStripModel::kNoTab) {
    return;
  }
  if (model->IsTabPinned(at) != static_cast<bool>(pinned)) {
    at = model->SetTabPinned(at, pinned);
  }
  const int pinned_count = model->IndexOfFirstNonPinnedTab();
  int to = std::clamp(index, 0, model->count() - 1);
  to = pinned ? std::min(to, pinned_count - 1) : std::max(to, pinned_count);
  if (to != at) {
    model->MoveWebContentsAt(at, to, false);
  }
}

- (AircTab*)restoreTab:(NSString*)state
                 profile:(AircProfile*)profile
              foreground:(BOOL)foreground {
  if (airc::IsNotifyingTabStrip()) {
    return nil;
  }
  std::optional<std::vector<uint8_t>> bytes =
      state ? base::Base64Decode(base::SysNSStringToUTF8(state)) : std::nullopt;
  Browser* browser = profile.chromeProfile ? _host->BrowserFor(profile.chromeProfile) : nullptr;
  if (!bytes || bytes->empty() || !browser) {
    return nil;
  }
  base::Pickle pickle = base::Pickle::WithUnownedBuffer(*bytes);
  base::PickleIterator it(pickle);
  int version = 0, selected = 0, count = 0;
  if (!it.ReadInt(&version) || version != 1 || !it.ReadInt(&selected) ||
      !it.ReadInt(&count) || count <= 0 || count > 1000) {
    return nil;
  }
  std::vector<sessions::SerializedNavigationEntry> navigations;
  for (int i = 0; i < count; ++i) {
    sessions::SerializedNavigationEntry entry;
    if (!entry.ReadFromPickle(&it)) {
      return nil;
    }
    navigations.push_back(std::move(entry));
  }
  selected = std::clamp(selected, 0, count - 1);
  auto pending = _host->ScopedPendingOpen(
      {foreground ? WindowOpenDisposition::NEW_FOREGROUND_TAB
                  : WindowOpenDisposition::NEW_BACKGROUND_TAB,
       nullptr});
  content::WebContents* contents = chrome::AddRestoredTab(
      browser, navigations, browser->GetTabStripModel()->count(), selected,
      std::string(), std::nullopt, foreground,
      false, base::TimeTicks::Now(), base::Time::Now(),
      nullptr, sessions::SerializedUserAgentOverride(),
      {}, false,
      std::nullopt);
  return contents ? airc::TabBridge::GetOrCreate(contents)->tab() : nil;
}

- (AircTab*)duplicateTab:(AircTab*)source
                   profile:(AircProfile*)profile
                foreground:(BOOL)foreground {
  if (airc::IsNotifyingTabStrip()) {
    return nil;
  }
  content::WebContents* contents = source.contents;
  Profile* chrome_profile = profile.chromeProfile;
  if (!contents || !chrome_profile ||
      Profile::FromBrowserContext(contents->GetBrowserContext()) != chrome_profile) {
    return nil;
  }
  Browser* browser = _host->BrowserFor(chrome_profile);
  if (!browser) {
    return nil;
  }
  std::unique_ptr<content::WebContents> copy = contents->Clone();
  content::WebContents* raw = copy.get();
  auto pending = _host->ScopedPendingOpen(
      {foreground ? WindowOpenDisposition::NEW_FOREGROUND_TAB
                  : WindowOpenDisposition::NEW_BACKGROUND_TAB,
       contents->GetWeakPtr()});
  TabStripModel* model = browser->GetTabStripModel();
  model->InsertWebContentsAt(model->count(), std::move(copy),
                             foreground ? AddTabTypes::ADD_ACTIVE : AddTabTypes::ADD_NONE);
  return airc::TabBridge::GetOrCreate(raw)->tab();
}

- (void)prepareProfile:(AircProfile*)profile {
  if (profile.chromeProfile) {
    _host->BrowserFor(profile.chromeProfile);
  }
}

- (void)deactivateAll {
  [self closeActionPopup];
  for (Browser* browser : _host->browsers()) {
    for (AircTab* tab in [self tabsForProfile:[AircProfile wrapperFor:browser->GetProfile()]]) {
      [tab detachFromHost];
    }
  }
  _host->SetActiveProfile(nullptr);
}

- (void)close {
  [self closeActionPopup];
  _host->Close();
}

@end

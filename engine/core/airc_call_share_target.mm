// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#import "airc/core/public/Airc.h"
#import "airc/core/airc_internal.h"
#import "airc/core/airc_api_internal.h"
#include "airc/core/airc_call_share_target.h"
#include "airc/core/airc_browser.h"
#include <map>
#include "base/no_destructor.h"
#include "base/time/time.h"
#include "base/memory/weak_ptr.h"
#include "base/supports_user_data.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/tab_sharing/tab_sharing_infobar_delegate.h"
#include "components/infobars/content/content_infobar_manager.h"
#include "components/infobars/core/infobar.h"
#include "content/public/browser/web_contents.h"

namespace airc {
namespace {
struct Share {
  base::WeakPtr<content::WebContents> capturer, shared;
  base::WeakPtr<Profile> profile;
  bool switchable;
  base::TimeTicks switching_at;
};
auto& Shares() {
  static base::NoDestructor<std::map<TabSharingUI*, Share>> shares;
  return *shares;
}
// Source replacement crosses the UI/IO threads: the old TabSharingUI dies
// before the new one starts. Keep the confirmed source through that handoff.
auto& PendingSwitches() {
  static base::NoDestructor<std::map<content::WebContents*, Share>> pending;
  return *pending;
}
const char kObserver = 0;
class Observer : public base::SupportsUserData::Data {
 public:
  void (^handler)(NSArray*) = nil;
  NSDictionary* previous = @{};
};
NSArray* Snapshot(Profile* profile) {
  NSMutableArray* result = [NSMutableArray array];
  auto append = [&](const Share& share) {
    if (!share.capturer || !share.shared || share.capturer->GetBrowserContext() != profile)
      return;
    AircTab* capturer = TabBridge::GetOrCreate(share.capturer.get())->tab();
    AircTab* shared = TabBridge::GetOrCreate(share.shared.get())->tab();
    if (capturer && shared)
      [result addObject:@{@"capturerID": @(capturer.tabId), @"sharedTabID": @(shared.tabId),
                          @"state": @"capturing", @"capturing": @YES,
                          @"switchable": @(share.switchable && share.switching_at.is_null())}];
  };
  for (const auto& [ui, share] : Shares()) append(share);
  for (const auto& [capturer, pending] : PendingSwitches()) {
    bool active = false;
    for (const auto& [ui, share] : Shares()) {
      if (share.capturer.get() == capturer) { active = true; break; }
    }
    if (!active) append(pending);
  }
  return result;
}
void Notify(Profile* profile) {
  if (!profile) return;
  auto weak = profile->GetWeakPtr();
  // Deliver confirmed source IDs, retaining the previous source while a
  // replacement crosses threads; never publish the requested target early.
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!weak) return;
    auto* observer = static_cast<Observer*>(weak->GetUserData(&kObserver));
    if (!observer || !observer->handler) return;
    NSMutableDictionary* current = [NSMutableDictionary dictionary];
    NSMutableArray* result = [NSMutableArray array];
    for (NSDictionary* row in Snapshot(weak.get())) {
      NSNumber* key = row[@"capturerID"];
      current[key] = row[@"sharedTabID"];
      NSMutableDictionary* event = [row mutableCopy];
      if (observer->previous[key] && ![observer->previous[key] isEqual:current[key]])
        event[@"state"] = @"switched";
      [result addObject:event];
    }
    if ([current isEqual:observer->previous]) return;
    for (NSNumber* key in observer->previous) {
      if (!current[key]) [result addObject:@{@"capturerID": key, @"sharedTabID": observer->previous[key],
                                           @"state": @"stopped", @"capturing": @NO, @"switchable": @NO}];
    }
    observer->previous = current;
    observer->handler(result);
  });
}
}
void CallShareChanged(TabSharingUI* ui, content::WebContents* capturer,
                      content::WebContents* shared, bool switchable) {
  Profile* profile = nullptr;
  auto old = Shares().find(ui);
  if (old != Shares().end()) {
    profile = old->second.profile.get();
    Shares().erase(old);
  }
  if (capturer && shared) {
    PendingSwitches().erase(capturer);
    profile = Profile::FromBrowserContext(capturer->GetBrowserContext());
    Shares()[ui] = {capturer->GetWeakPtr(), shared->GetWeakPtr(), profile->GetWeakPtr(), switchable};
  }
  Notify(profile);
}
void CallShareSwitchRequested(content::WebContents* capturer) {
  for (auto& [ui, share] : Shares()) {
    if (share.capturer.get() != capturer) continue;
    share.switching_at = base::TimeTicks::Now();
    PendingSwitches()[capturer] = share;
    auto token = share.switching_at;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      auto found = PendingSwitches().find(capturer);
      if (found == PendingSwitches().end() || found->second.switching_at != token) return;
      auto profile = found->second.profile;
      PendingSwitches().erase(found);
      for (auto& [ui, current] : Shares()) {
        if (current.capturer.get() == capturer) current.switching_at = base::TimeTicks();
      }
      Notify(profile.get());
    });
  }
}
void CallShareSwitchCancelled(content::WebContents* capturer) {
  auto found = PendingSwitches().find(capturer);
  if (found == PendingSwitches().end()) return;
  auto profile = found->second.profile;
  PendingSwitches().erase(found);
  Notify(profile.get());
}
TabSharingInfoBarDelegate* CallShareDelegate(content::WebContents* target,
                                            content::WebContents* capturer) {
  // Exact BrowserContext equality includes the OTR identity. Never compare the
  // original profile: that would admit private targets from a normal call.
  if (!target || !capturer || target->GetBrowserContext() != capturer->GetBrowserContext())
    return nullptr;
  TabSharingUI* session = nullptr;
  for (auto& [ui, share] : Shares()) {
    if (share.capturer.get() != capturer) continue;
    if (!share.switching_at.is_null() && base::TimeTicks::Now() - share.switching_at < base::Seconds(5)) return nullptr;
    if (session || share.shared.get() == target) return nullptr; // ambiguous / already shared
    session = ui;
  }
  if (!session) return nullptr;
  auto* manager = infobars::ContentInfoBarManager::FromWebContents(target);
  if (!manager) return nullptr;
  for (const auto& infobar : manager->infobars()) {
    auto* delegate = infobar->delegate();
    if (delegate->GetIdentifier() != infobars::InfoBarDelegate::TAB_SHARING_INFOBAR_DELEGATE)
      continue;
    auto* sharing = static_cast<TabSharingInfoBarDelegate*>(delegate);
    if (sharing->airc_ui() == session) return sharing;
  }
  return nullptr;
}
}
@implementation AircProfile (CallSharing)
- (NSArray<NSDictionary<NSString*, id>*>*)callShares { return airc::Snapshot(self.chromeProfile); }
- (void)observeCallShares:(void (^)(NSArray<NSDictionary<NSString*, id>*>*))handler {
  auto* profile = self.chromeProfile;
  if (!profile) return;
  if (!handler) { profile->RemoveUserData(&airc::kObserver); return; }
  auto observer = std::make_unique<airc::Observer>();
  observer->handler = [handler copy];
  NSArray* initial = [self callShares];
  NSMutableDictionary* previous = [NSMutableDictionary dictionary];
  for (NSDictionary* row in initial) previous[row[@"capturerID"]] = row[@"sharedTabID"];
  observer->previous = previous;
  profile->SetUserData(&airc::kObserver, std::move(observer));
  handler(initial);
}
@end

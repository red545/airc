// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#import "airc/core/public/Airc.h"
#import "airc/core/airc_internal.h"
#import "airc/core/airc_api_internal.h"
#include "airc/core/airc_memory.h"
#include "airc/core/airc_launch_switches.h"
#include "airc/core/airc_host_visibility.h"
#include <algorithm>
#include <cmath>
#include <memory>
#include <set>
#include <vector>
#include "base/functional/bind.h"
#include "base/memory/weak_ptr.h"
#include "base/values.h"
#include "chrome/common/chrome_isolated_world_ids.h"
#include "content/public/browser/render_frame_host.h"
#include "base/feature_list.h"
#include "content/public/common/content_features.h"
#include "base/memory/memory_pressure_listener.h"
#include "base/memory/memory_pressure_listener_registry.h"
#include "base/no_destructor.h"
#include "base/supports_user_data.h"
#include "base/timer/timer.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/performance_manager/policies/discard_eligibility_policy.h"
#include "components/performance_manager/public/decorators/page_live_state_decorator.h"
#include "content/public/browser/media_session.h"
#include "chrome/browser/resource_coordinator/tab_lifecycle_unit_external.h"
#include "components/performance_manager/public/performance_manager.h"
#include "components/performance_manager/public/graph/page_node.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/web_contents_user_data.h"

namespace airc {
namespace {
const int kTimeoutKey = 0;
struct Timeout : base::SupportsUserData::Data {
  base::TimeDelta value = base::Minutes(30);
};
base::TimeDelta TimeoutFor(content::BrowserContext* profile) {
  auto* data = static_cast<Timeout*>(profile->GetUserData(&kTimeoutKey));
  return data ? data->value : base::Minutes(30);
}
class TabMemory;
std::set<TabMemory*>& Tabs() {
  static base::NoDestructor<std::set<TabMemory*>> tabs;
  return *tabs;
}
class TabMemory : public content::WebContentsObserver,
                  public content::WebContentsUserData<TabMemory> {
 public:
  ~TabMemory() override { Tabs().erase(this); }
  base::TimeTicks hidden_since = base::TimeTicks::Now();
  void Schedule() {
    timer_.Stop();
    if (!web_contents() || ShownByHost(web_contents()).value_or(false) ||
        web_contents()->GetVisibility() == content::Visibility::VISIBLE ||
        web_contents()->WasDiscarded()) return;
    auto timeout = TimeoutFor(web_contents()->GetBrowserContext());
    if (timeout.is_zero()) return;
    timer_.Start(FROM_HERE, std::max(base::TimeDelta(),
        hidden_since + timeout - base::TimeTicks::Now()), this, &TabMemory::Expire);
  }
  content::WebContents* contents() { return web_contents(); }
 private:
  friend class content::WebContentsUserData<TabMemory>;
  explicit TabMemory(content::WebContents* contents)
      : content::WebContentsObserver(contents), content::WebContentsUserData<TabMemory>(*contents) {
    Tabs().insert(this);
    Schedule();
  }
  void Expire() {
    // PM tracks actual user input. Also preserve script-restored form values
    // (including the app's event fixture), without trusting page-world JS hooks.
    struct Check { size_t remaining; bool dirty = false; };
    std::vector<content::RenderFrameHost*> frames;
    web_contents()->ForEachRenderFrameHost([&](content::RenderFrameHost* frame) {
      if (frame->IsRenderFrameLive()) frames.push_back(frame);
    });
    if (frames.empty()) return;
    auto check = std::make_shared<Check>(frames.size());
    auto weak = weak_factory_.GetWeakPtr();
    for (auto* frame : frames) {
      frame->ExecuteJavaScriptInIsolatedWorld(
          u"Array.from(document.querySelectorAll('input,textarea,select,[contenteditable]')).some(e => "
          u"e.isContentEditable ? e.textContent.length > 0 : e.tagName === 'SELECT' ? "
          u"Array.from(e.options).some(o => o.selected !== o.defaultSelected) : "
          u"(e.type === 'checkbox' || e.type === 'radio') ? e.checked !== e.defaultChecked : "
          u"e.value !== e.defaultValue)",
          base::BindOnce([](base::WeakPtr<TabMemory> memory, std::shared_ptr<Check> check,
                            base::Value result) {
            check->dirty |= !result.is_bool() || result.GetBool();
            if (--check->remaining == 0 && memory && !check->dirty)
              DiscardSafely(memory->web_contents());
          }, weak, check), ISOLATED_WORLD_ID_CHROME_INTERNAL);
    }
  }
  void DidStartNavigation(content::NavigationHandle*) override {
    weak_factory_.InvalidateWeakPtrs();
  }
  void OnVisibilityChanged(content::Visibility visibility) override {
    hidden_since = base::TimeTicks::Now();
    Schedule();
  }
  void DidStopLoading() override { Schedule(); }
  void OnAudioStateChanged(bool audible) override { if (!audible) Schedule(); }
  void WebContentsDestroyed() override { timer_.Stop(); Tabs().erase(this); }
  base::OneShotTimer timer_;
  base::WeakPtrFactory<TabMemory> weak_factory_{this};
  WEB_CONTENTS_USER_DATA_KEY_DECL();
};
WEB_CONTENTS_USER_DATA_KEY_IMPL(TabMemory);
class Pressure : public base::MemoryPressureListener {
 public:
  Pressure() : registration_(base::MemoryPressureListenerTag::kMemoryPressureListenerPolicy, this) {}
  void OnMemoryPressure(base::MemoryPressureLevel level) override {
    if ([g_delegate respondsToSelector:@selector(engine:memoryPressure:)])
      [g_delegate engine:g_engine memoryPressure:static_cast<NSInteger>(level)];
    if (level == base::MEMORY_PRESSURE_LEVEL_NONE) return;
    std::vector<TabMemory*> sorted(Tabs().begin(), Tabs().end());
    std::ranges::sort(sorted, {}, &TabMemory::hidden_since);
    // One eligible LRU tab per signal. Chromium repeats sustained pressure signals.
    for (auto* tab : sorted) if (DiscardSafely(tab->contents())) break;
  }
 private:
  base::MemoryPressureListenerRegistration registration_;
};
std::unique_ptr<Pressure> pressure;
}
void StartMemoryPolicy() { pressure = std::make_unique<Pressure>(); }
void StopMemoryPolicy() { pressure.reset(); }
void TrackTabMemory(content::WebContents* contents) { TabMemory::CreateForWebContents(contents); }
void MemoryHostVisibilityChanged(content::WebContents* contents) {
  if (auto* memory = TabMemory::FromWebContents(contents)) {
    memory->hidden_since = base::TimeTicks::Now();
    memory->Schedule();
  }
}
bool DiscardSafely(content::WebContents* contents) {
  if (!base::FeatureList::IsEnabled(features::kWebContentsDiscard)) return false;
  if (!contents || contents->WasDiscarded() || contents->IsLoading() ||
      ShownByHost(contents).value_or(false) ||
      contents->GetVisibility() == content::Visibility::VISIBLE ||
      contents->IsCurrentlyAudible() || contents->IsBeingCaptured()) return false;
  using performance_manager::PerformanceManager;
  if (!PerformanceManager::IsAvailable()) return false;
  auto page = PerformanceManager::GetPrimaryPageNodeForWebContents(contents);
  // Fail closed: Chromium tracks edits across subframes and contenteditable too.
  if (!page || page->HadFormInteraction() || page->HadUserEdits()) return false;
  // Chromium 156's discard policy does not yet cover WebRTC, HID/serial or
  // silent active media sessions. Keep these in addition to its eligibility.
  using performance_manager::PageLiveStateDecorator;
  if (page->UsesWebRTC() ||
      PageLiveStateDecorator::IsConnectedToHidDevice(contents) ||
      PageLiveStateDecorator::IsConnectedToSerialPort(contents)) return false;
  if (auto* session = content::MediaSession::GetIfExists(contents)) {
    auto info = session->GetMediaSessionInfoSync();
    if (info && info->state ==
        media_session::mojom::MediaSessionInfo::SessionState::kActive) return false;
  }
  using namespace performance_manager::policies;
  auto* policy = DiscardEligibilityPolicy::GetFromGraph(PerformanceManager::GetGraph());
  if (!policy) return false;
  std::vector<CannotDiscardReason> reasons;
  // Airc owns the timeout/LRU, so only override the recent-visibility grace.
  // EXTERNAL eligibility skips capture, PiP, devices, edits and other safeguards.
  auto eligibility = policy->CanDiscard(page.get(),
      ::mojom::LifecycleUnitDiscardReason::PROACTIVE,
      /*ignore_recent_visibility=*/true, &reasons);
  if (eligibility == CanDiscardResult::kDisallowed) return false;
  for (auto reason : reasons) {
    // Each profile retains a selected Chromium tab even when its Space is away.
    // Only the explicit host-hidden signal overrides this one strip-level veto.
    if (reason == CannotDiscardReason::kActiveTab &&
        ShownByHost(contents) == false) continue;
    return false;
  }
  if (eligibility != CanDiscardResult::kEligible && reasons.empty()) return false;
  auto* unit = resource_coordinator::TabLifecycleUnitExternal::FromWebContents(contents);
  return unit && unit->IsAutoDiscardable() &&
      unit->DiscardTab(::mojom::LifecycleUnitDiscardReason::EXTERNAL);
}
}
@implementation AircProfile (Memory)
- (NSTimeInterval)unloadTimeout {
  return self.chromeProfile ? airc::TimeoutFor(self.chromeProfile).InSecondsF() : 1800;
}
- (void)setUnloadTimeout:(NSTimeInterval)seconds {
  if (!self.chromeProfile || !std::isfinite(seconds) || seconds < 0) return;
  auto value = std::make_unique<airc::Timeout>();
  value->value = base::Seconds(seconds);
  self.chromeProfile->SetUserData(&airc::kTimeoutKey, std::move(value));
  for (auto* tab : airc::Tabs())
    if (tab->contents()->GetBrowserContext() == self.chromeProfile) tab->Schedule();
}
@end

@implementation AircEngine (MemoryTesting)
+ (BOOL)simulateMemoryPressureForTesting:(NSInteger)level {
  if (!airc::TestInstance() || level < 1 || level > 2) return NO;
  base::MemoryPressureListener::SimulatePressureNotification(static_cast<base::MemoryPressureLevel>(level));
  return YES;
}
@end

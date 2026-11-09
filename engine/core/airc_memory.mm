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
#include "airc_discard_request.h"
// The public API cannot acknowledge a history-state flush. The static framework
// already links these implementations through content/public/browser.
#include "content/browser/renderer_host/render_view_host_impl.h"  // nogncheck
#include "content/browser/renderer_host/page_lifecycle_state_manager.h"  // nogncheck
#include "base/memory/weak_ptr.h"
#include "base/values.h"
#include "chrome/common/chrome_isolated_world_ids.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_process_host.h"
#include "third_party/blink/public/mojom/frame/sudden_termination_disabler_type.mojom.h"
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
bool CanDiscard(content::WebContents* contents);
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
  void HostVisibilityChanged() {
    if (ShownByHost(web_contents()).value_or(false)) CancelDiscard("host-visible");
    hidden_since = base::TimeTicks::Now();
    Schedule();
  }
  bool DiscardAfterStateFlush() {
    if (discard_request_.pending()) return false;
    std::set<content::RenderViewHostImpl*> views;
    web_contents()->GetPrimaryMainFrame()->ForEachRenderFrameHost(
        [&](content::RenderFrameHost* frame) {
          if (frame->IsRenderFrameLive())
            views.insert(static_cast<content::RenderViewHostImpl*>(frame->GetRenderViewHost()));
        });
    if (views.empty()) return false;
    for (auto* view : views)
      if (!view->GetAssociatedPageBroadcast().is_bound()) return false;
    auto* primary = static_cast<content::RenderViewHostImpl*>(
        web_contents()->GetPrimaryMainFrame()->GetRenderViewHost());
    was_frozen_ = primary->GetPageLifecycleStateManager()->CalculatePageLifecycleState()->is_frozen;
    const bool new_intent = !discard_request_.active();
    auto request = discard_request_.Begin(views.size());
    if (!request) return false;
    discard_retry_.Stop();
    if (new_intent) {
      discard_started_ = base::TimeTicks::Now();
      discard_deadline_.Start(FROM_HERE,
          base::Seconds(DiscardRequest::kFallbackSeconds), this, &TabMemory::DiscardFallback);
    }
    Trace("freeze-begin");
    // RenderFrameImpl::WillFreezePage sends the current PageState immediately,
    // including scroll offsets, instead of waiting for the 1/5-second sync timer.
    web_contents()->SetPageFrozen(true);
    discard_timeout_.Start(FROM_HERE, base::Seconds(2), this, &TabMemory::DiscardTimedOut);
    size_t renderer = 0;
    for (auto* view : views) {
      // SetPageFrozen already sent this state through the lifecycle manager. The
      // identical state is a native acknowledgement barrier, not another freeze.
      // These channel-associated replies follow the frames' UpdateState messages.
      // Await every primary-page renderer, including out-of-process subframes.
      view->GetAssociatedPageBroadcast()->SetPageLifecycleState(
          view->GetPageLifecycleStateManager()->CalculatePageLifecycleState(),
          nullptr, base::BindOnce(&TabMemory::RendererAcknowledged,
              discard_weak_factory_.GetWeakPtr(), *request, renderer++));
    }
    return true;
  }
 private:
  void Trace(const char* event) {
    if (Traced("discard"))
      NSLog(@"AIRC-DISCARD %p %s shown=%d visibility=%d loading=%d pending=%d",
          static_cast<void*>(this), event, ShownByHost(web_contents()).value_or(false),
          static_cast<int>(web_contents()->GetVisibility()),
          web_contents()->IsLoading(), discard_request_.pending());
  }
  void RendererAcknowledged(DiscardRequest::Token request, size_t renderer) {
    if (discard_request_.Acknowledge(request, renderer)) {
      Trace("all-acks");
      FinishDiscard();
    }
  }
  void RestoreFreezeState() {
    // Showing the page implicitly thaws it. SetPageFrozen is invalid on a
    // visible WebContents; never refreeze a page the person just selected.
    if (!was_frozen_ && web_contents() &&
        web_contents()->GetVisibility() != content::Visibility::VISIBLE)
      web_contents()->SetPageFrozen(false);
  }
  void DiscardTimedOut() {
    if (!discard_request_.pending()) return;
    discard_weak_factory_.InvalidateWeakPtrs();
    auto delay = base::Seconds(*discard_request_.RetryAfterTimeout());
    RestoreFreezeState();
    if (discard_request_.CanFallback(
            (base::TimeTicks::Now() - discard_started_).InSecondsF())) {
      Trace("ack-timeout-limit");
      FinishDiscard(/*fallback=*/true);
      return;
    }
    Trace("ack-timeout-retry");
    // The automatic one-shot has already fired. A lost ACK must not leave an
    // otherwise eligible page loaded until another tab event happens. Recheck
    // form input and all current protections on the next attempt, even for a
    // pressure or explicit request with the automatic timeout disabled.
    discard_retry_.Start(FROM_HERE, delay, this, &TabMemory::Expire);
  }
  void CancelDiscard(const char* reason) {
    if (discard_request_.active()) Trace(reason);
    discard_deadline_.Stop();
    discard_retry_.Stop();
    discard_timeout_.Stop();
    // Also cancel a retry's form query if selection/navigation overtakes it.
    weak_factory_.InvalidateWeakPtrs();
    discard_weak_factory_.InvalidateWeakPtrs();
    bool was_pending = discard_request_.pending();
    discard_request_.Cancel();
    if (was_pending) RestoreFreezeState();
  }
  void DiscardFallback() {
    if (!discard_request_.CanFallback(
            (base::TimeTicks::Now() - discard_started_).InSecondsF())) return;
    // A hung renderer cannot answer another form query or flush fresh history.
    // Use only the checkpoint already received by Chromium. Browser-side edit,
    // media, capture and visibility vetoes still apply; never bypass them.
    FinishDiscard(/*fallback=*/true);
  }
  bool StopHungRendererForFallback() {
    auto* main = web_contents()->GetPrimaryMainFrame();
    auto* process = main->GetProcess();
    bool before_unload = false;
    web_contents()->ForEachRenderFrameHost([&](content::RenderFrameHost* frame) {
      before_unload |= frame->GetSuddenTerminationDisablerState(
          blink::mojom::SuddenTerminationDisablerType::kBeforeUnloadHandler);
    });
    if (before_unload) {
      Trace("fallback-beforeunload-veto");
      return false;
    }
    // Keep any other page in this process, including inactive frames. Chromium's
    // own fast-shutdown check also excludes pending views, workers, keep-alives
    // and pending process reuse. Never kill a shared renderer to free one tab.
    bool shared = false;
    process->ForEachRenderFrameHost([&](content::RenderFrameHost* frame) {
      shared |= frame->GetOutermostMainFrame() != main->GetOutermostMainFrame();
    });
    if (shared) {
      Trace("fallback-shared-renderer-veto");
      return false;
    }
    // Normal discard preserves unload/pagehide/visibility handlers. A renderer
    // stuck forever in its freeze handler cannot run them or its Discard IPC.
    // After the bounded fallback, ignore those handlers only for this one page;
    // beforeunload and every native safety veto have already been checked.
    auto weak = discard_weak_factory_.GetWeakPtr();
    const bool stopped = process->FastShutdownIfPossible(
        /*page_count=*/1u, /*skip_unload_handlers=*/true,
        /*ignore_workers=*/false, /*ignore_keep_alive=*/false,
        /*ignore_pending_reuse=*/false, /*use_outermost_main_frame_check=*/true);
    if (weak) weak->Trace(stopped ? "fallback-renderer-stopped"
                                 : "fallback-protected-renderer-veto");
    return stopped;
  }
  void FinishDiscard(bool fallback = false) {
    if (!discard_request_.active() || (!fallback && !discard_request_.pending())) return;
    bool was_pending = discard_request_.pending();
    discard_deadline_.Stop();
    discard_retry_.Stop();
    timer_.Stop();
    weak_factory_.InvalidateWeakPtrs();
    discard_timeout_.Stop();
    discard_weak_factory_.InvalidateWeakPtrs();
    discard_request_.Cancel();
    // Recheck browser-side safety vetoes after waiting. A completed retry form
    // query also cancels dirty pages; the last-checkpoint fallback cannot ask a
    // hung renderer for fresh DOM state.
    auto weak = discard_weak_factory_.GetWeakPtr();
    bool eligible = CanDiscard(web_contents());
    Trace(fallback ? (eligible ? "fallback-check" : "fallback-veto")
                   : (eligible ? "discard" : "post-ack-veto"));
    if (eligible && fallback) {
      eligible = StopHungRendererForFallback();
      if (!weak) return;
      if (eligible) Trace("fallback-last-checkpoint");
    }
    if (eligible) {
      auto* unit = resource_coordinator::TabLifecycleUnitExternal::FromWebContents(web_contents());
      bool accepted = unit->DiscardTab(::mojom::LifecycleUnitDiscardReason::EXTERNAL);
      if (weak) weak->Trace(accepted && weak->web_contents()->WasDiscarded()
                                ? "discarded" : "native-not-discarded");
    }
    // Do not leave our temporary freeze behind after a veto, or on a discarded
    // view that will later be reloaded in the background. A discard observer may
    // close the tab synchronously, so do not access this after its destruction.
    if (weak && was_pending) weak->RestoreFreezeState();
  }
  friend class content::WebContentsUserData<TabMemory>;
  explicit TabMemory(content::WebContents* contents)
      : content::WebContentsObserver(contents), content::WebContentsUserData<TabMemory>(*contents) {
    Tabs().insert(this);
    Schedule();
  }
  void Expire() {
    if (!CanDiscard(web_contents())) { CancelDiscard("pre-query-veto"); return; }
    // PM tracks actual user input. Also preserve script-restored form values
    // (including the app's event fixture), without trusting page-world JS hooks.
    struct Check { size_t remaining; bool dirty = false; };
    std::vector<content::RenderFrameHost*> frames;
    web_contents()->ForEachRenderFrameHost([&](content::RenderFrameHost* frame) {
      if (frame->IsRenderFrameLive()) frames.push_back(frame);
    });
    if (frames.empty()) { CancelDiscard("no-live-frame"); return; }
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
            if (--check->remaining != 0 || !memory) return;
            if (check->dirty) memory->CancelDiscard("form-dirty");
            else if (!DiscardSafely(memory->web_contents()) && !memory->discard_request_.pending())
              memory->CancelDiscard("form-complete-veto");
          }, weak, check), ISOLATED_WORLD_ID_CHROME_INTERNAL);
    }
  }
  void DidStartNavigation(content::NavigationHandle*) override {
    CancelDiscard("navigation");
  }
  void OnVisibilityChanged(content::Visibility visibility) override {
    if (visibility == content::Visibility::VISIBLE) CancelDiscard("native-visible");
    hidden_since = base::TimeTicks::Now();
    Schedule();
  }
  void DidStopLoading() override { Schedule(); }
  void OnAudioStateChanged(bool audible) override { if (!audible) Schedule(); }
  void WebContentsDestroyed() override {
    timer_.Stop();
    discard_retry_.Stop();
    discard_deadline_.Stop();
    discard_timeout_.Stop();
    discard_weak_factory_.InvalidateWeakPtrs();
    discard_request_.Cancel();
    Tabs().erase(this);
  }
  base::OneShotTimer timer_;
  base::OneShotTimer discard_timeout_;
  base::OneShotTimer discard_retry_;
  base::OneShotTimer discard_deadline_;
  base::TimeTicks discard_started_;
  DiscardRequest discard_request_;
  bool was_frozen_ = false;
  base::WeakPtrFactory<TabMemory> weak_factory_{this};
  base::WeakPtrFactory<TabMemory> discard_weak_factory_{this};
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
  if (auto* memory = TabMemory::FromWebContents(contents))
    memory->HostVisibilityChanged();
}
namespace {
bool CanDiscard(content::WebContents* contents) {
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
  return unit && unit->IsAutoDiscardable();
}
}  // namespace
bool DiscardSafely(content::WebContents* contents) {
  if (!CanDiscard(contents)) return false;
  auto* memory = TabMemory::FromWebContents(contents);
  return memory && memory->DiscardAfterStateFlush();
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

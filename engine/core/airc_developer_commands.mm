// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#import "airc/core/airc_tab_internal.h"
#include "airc/core/airc_developer_commands.h"
#include "airc/core/airc_devtools_call.h"
#include <memory>
#include <utility>
#include "base/functional/bind.h"
#include "base/barrier_closure.h"
#include "base/strings/sys_string_conversions.h"
#include "base/supports_user_data.h"
#include "base/task/single_thread_task_runner.h"
#include "chrome/browser/devtools/devtools_window.h"
#include "chrome/browser/devtools/devtools_toggle_action.h"
#include "content/public/browser/browsing_data_filter_builder.h"
#include "content/public/browser/browser_context.h"
#include "net/base/registry_controlled_domains/registry_controlled_domain.h"
#include "services/network/public/mojom/network_context.mojom.h"
#include "services/network/public/mojom/clear_data_filter.mojom.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/weak_document_ptr.h"
#include "third_party/blink/public/common/storage_key/storage_key.h"
#include "url/origin.h"
#include "ui/gfx/geometry/rect.h"
#include "services/network/public/mojom/cookie_manager.mojom.h"

namespace {
using Done = void (^)(NSString* _Nullable);
// `off_the_record`: a private tab's own site (P20d's cookie/cache clears reach only its off-the-record partition).
std::string SiteDataDomain(content::WebContents* contents, bool off_the_record = false) {
  if (!contents || contents->IsBeingDestroyed()) return {};
  if (!off_the_record && contents->GetBrowserContext()->IsOffTheRecord()) return {};
  const auto& url = contents->GetLastCommittedURL();
  if (!url.SchemeIsHTTPOrHTTPS()) return {};
  auto domain = net::registry_controlled_domains::GetDomainAndRegistry(
      url, net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES);
  return domain.empty() ? std::string(url.host()) : domain;
}
struct ToolsState : base::SupportsUserData::Data {
  unsigned generation = 0;
  base::WeakPtr<content::WebContents> closing_frontend;
  base::WeakPtr<content::WebContents> observed_frontend;
  base::WeakPtr<content::WebContents> ready_frontend;
};
ToolsState* State(content::WebContents* contents) {
  static int key;
  auto* state = static_cast<ToolsState*>(contents->GetUserData(&key));
  if (!state) {
    auto owned = std::make_unique<ToolsState>();
    state = owned.get(); contents->SetUserData(&key, std::move(owned));
  }
  return state;
}
// Wait for the *same* frontend to finish docking. Never reopen it from a delayed callback.
void SelectPanel(base::WeakPtr<content::WebContents> inspected,
                 base::WeakPtr<content::WebContents> frontend,
                 unsigned generation, std::string panel, base::TimeTicks deadline, Done done) {
  if (!inspected || !frontend || inspected->IsBeingDestroyed() || frontend->IsBeingDestroyed() ||
      State(inspected.get())->generation != generation) {
    done(@"Developer tools or the inspected tab closed."); return;
  }
  if (State(inspected.get())->ready_frontend.get() != frontend.get() ||
      DevToolsWindow::GetInTabWebContents(inspected.get(), nullptr) != frontend.get()) {
    if (base::TimeTicks::Now() >= deadline) {
      done(@"Docked developer tools did not become ready within ten seconds."); return;
    }
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(FROM_HERE,
      base::BindOnce(&SelectPanel, inspected, frontend, generation, panel, deadline, done), base::Milliseconds(50));
    return;
  }
  base::DictValue params;
  // The name is validated against a fixed allowlist before interpolation. Unlike the
  // toggle action, the frontend API also selects a panel in an existing inspector.
  params.Set("expression", "DevToolsAPI.showPanel('" + panel + "'); true");
  params.Set("returnByValue", true);
  airc::CallDevTools(frontend.get(), "Runtime.evaluate", std::move(params), base::Seconds(10),
    base::BindOnce([](base::WeakPtr<content::WebContents> inspected,
                     base::WeakPtr<content::WebContents> frontend, unsigned generation, Done done,
                     std::optional<base::DictValue> result, std::optional<std::string> error) {
      if (!inspected || !frontend || State(inspected.get())->generation != generation ||
          DevToolsWindow::GetInTabWebContents(inspected.get(), nullptr) != frontend.get()) {
        done(@"Developer tools closed before panel selection finished."); return;
      }
      if (error || !result || result->contains("exceptionDetails")) {
        done(error ? base::SysUTF8ToNSString(*error) : @"Developer tools could not select the requested panel.");
      } else { done(nil); }
    }, inspected, frontend, generation, done));
}
// An explicit new show after close waits for the old frontend to die. It must
// not select a closing frontend, or let a close during this wait reopen a window.
void OpenPanel(base::WeakPtr<content::WebContents> inspected, unsigned generation,
               std::string panel, base::TimeTicks deadline, Done done) {
  if (!inspected || inspected->IsBeingDestroyed() || State(inspected.get())->generation != generation) {
    done(@"Developer tools request cancelled by tab or inspector close."); return;
  }
  if (State(inspected.get())->closing_frontend) {
    if (base::TimeTicks::Now() >= deadline) { done(@"Previous developer tools window is still closing."); return; }
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(FROM_HERE,
      base::BindOnce(&OpenPanel, inspected, generation, panel, deadline, done), base::Milliseconds(50));
    return;
  }
  DevToolsWindow::OpenDevToolsWindow(inspected.get(), DevToolsToggleAction::Show(),
                                    DevToolsOpenedByAction::kMainMenuOrMainShortcut);
  auto* window = DevToolsWindow::GetInstanceForInspectedWebContents(inspected.get());
  auto* frontend = window ? window->GetDevToolsWebContents().get() : nullptr;
  if (!frontend) { done(@"Developer tools are unavailable or disabled by policy."); return; }
  auto* state = State(inspected.get());
  if (state->observed_frontend.get() != frontend) {
    state->observed_frontend = frontend->GetWeakPtr();
    state->ready_frontend.reset();
    // Register once per frontend so concurrent panel calls do not overwrite each
    // other's completion. Docking alone can precede frontend event-listener setup.
    window->SetLoadCompletedCallback(base::BindOnce(
      [](base::WeakPtr<content::WebContents> inspected, base::WeakPtr<content::WebContents> frontend) {
        if (inspected && frontend && State(inspected.get())->observed_frontend.get() == frontend.get())
          State(inspected.get())->ready_frontend = frontend;
      }, inspected, frontend->GetWeakPtr()));
  }
  SelectPanel(inspected, frontend->GetWeakPtr(), generation, panel, deadline, done);
}
}  // namespace

namespace airc {
void CloseDeveloperTools(content::WebContents* contents) {
  if (!contents) return;
  auto* state = State(contents);
  ++state->generation;
  auto* window = DevToolsWindow::GetInstanceForInspectedWebContents(contents);
  if (window && window->GetDevToolsWebContents()) {
    state->closing_frontend = window->GetDevToolsWebContents()->GetWeakPtr();
    window->GetDevToolsWebContents()->ClosePage();
  }
}
}  // namespace airc

@implementation AircTab (DeveloperCommands)
- (void)showDevToolsPanel:(NSString*)panel completion:(void (^)(NSString* _Nullable))completion {
  const auto name = base::SysNSStringToUTF8(panel);
  if (!_contents || _contents->IsBeingDestroyed() || !airc::IsDeveloperPanel(name)) {
    completion(@"Tab closed or unsupported developer tools panel."); return;
  }
  OpenPanel(_contents->GetWeakPtr(), State(_contents)->generation, name,
            base::TimeTicks::Now() + base::Seconds(10), [completion copy]);
}

- (void)inspectElementAtPoint:(NSPoint)point completion:(void (^)(NSString* _Nullable))completion {
  if (!_contents || !airc::IsInspectPoint(point.x, point.y,
      _contents->GetContainerBounds().width(), _contents->GetContainerBounds().height())) {
    completion(@"Inspect point is outside the live tab viewport."); return;
  }
  const auto document = _contents->GetPrimaryMainFrame()->GetWeakDocumentPtr();
  auto weak = _contents->GetWeakPtr();
  const unsigned generation = State(_contents)->generation;
  [self showDevToolsPanel:@"elements" completion:^(NSString* error) {
    if (error) { completion(error); return; }
    auto* frame = document.AsRenderFrameHostIfValid();
    if (!weak || !frame || frame != weak->GetPrimaryMainFrame() ||
        State(weak.get())->generation != generation ||
        !DevToolsWindow::GetInTabWebContents(weak.get(), nullptr)) {
      completion(@"The inspected document navigated or developer tools closed."); return;
    }
    // Hit-test only once the frontend is attached, including child-frame routing.
    DevToolsWindow::InspectElement(frame, point.x, point.y);
    completion(nil);
  }];
}

- (NSString*)siteDataDomain {
  const auto domain = SiteDataDomain(_contents.get());
  return domain.empty() ? nil : base::SysUTF8ToNSString(domain);
}

- (void)clearSiteDataAndReload:(void (^)(NSString* _Nullable))completion {
  auto* contents = _contents.get();
  const auto domain = SiteDataDomain(contents);
  if (domain.empty()) {
    completion(@"unavailable:Clear site data requires a live HTTP or HTTPS page in a regular profile. Private windows are untouched."); return;
  }
  const auto document = contents->GetPrimaryMainFrame()->GetWeakDocumentPtr();
  auto weak = contents->GetWeakPtr();
  // The actual tab partition belongs to this profile; never use an original
  // profile or a caller-supplied domain. Private tabs were rejected above.
  auto* partition = contents->GetPrimaryMainFrame()->GetStoragePartition();
  using SP = content::StoragePartition;
  constexpr uint32_t mask = SP::REMOVE_DATA_MASK_COOKIES | SP::REMOVE_DATA_MASK_FILE_SYSTEMS |
    SP::REMOVE_DATA_MASK_INDEXEDDB | SP::REMOVE_DATA_MASK_LOCAL_STORAGE |
    SP::REMOVE_DATA_MASK_SERVICE_WORKERS | SP::REMOVE_DATA_MASK_CACHE_STORAGE |
    SP::REMOVE_DATA_MASK_MEDIA_LICENSES | SP::REMOVE_DATA_MASK_BACKGROUND_FETCH |
    SP::REMOVE_DATA_MASK_SHARED_STORAGE | SP::REMOVE_DATA_MASK_DEVICE_BOUND_SESSIONS;
  using Filter = content::BrowsingDataFilterBuilder;
  // Match the storage owner's site in all contexts. Do not erase another site's
  // third-party storage/cookies just because it was embedded on this site.
  auto filter = Filter::Create(Filter::Mode::kDelete, Filter::OriginMatchingMode::kOriginInAllContexts);
  filter->AddRegisterableDomain(domain);
  auto finished = std::make_shared<bool>(false);
  Done done = [completion copy];
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(FROM_HERE,
    base::BindOnce([](std::shared_ptr<bool> finished, Done done) {
      if (std::exchange(*finished, true)) return;
      done(@"partial:Site data removal timed out; removal may still finish, but no reload will be performed.");
    }, finished, done), base::Seconds(30));
  auto cleared = base::BarrierClosure(3, base::BindOnce(
    [](base::WeakPtr<content::WebContents> tab, content::WeakDocumentPtr document,
       std::shared_ptr<bool> finished, Done done) {
      if (std::exchange(*finished, true)) return;
      if (!tab || !document.AsRenderFrameHostIfValid() ||
          document.AsRenderFrameHostIfValid() != tab->GetPrimaryMainFrame() ||
          tab->GetController().GetPendingEntry()) {
        done(@"partial:Site data cleared, but the tab navigated or closed; no reload performed."); return;
      }
      tab->GetController().Reload(content::ReloadType::BYPASSING_CACHE, true);
      done(nil);
    }, weak, document, finished, done));
  partition->GetNetworkContext()->ClearHttpCache(base::Time(), base::Time(),
      filter->BuildNetworkServiceFilter(), cleared);
  partition->ClearCodeCaches(base::Time(), base::Time(), filter->BuildUrlFilter(), cleared);
  partition->ClearData(mask, filter.get(), {}, filter->BuildCookieDeletionFilter(),
      false, base::Time(), base::Time::Max(), cleared);
}

- (NSString*)developerSiteDomain {
  const auto domain = SiteDataDomain(_contents.get(), /*off_the_record=*/true);
  return domain.empty() ? nil : base::SysUTF8ToNSString(domain);
}

// P20d, Arc's Clear Cookies and Refresh / Clear Cache and Refresh: only the named types of this tab's site, in this
// tab's own storage partition (a private tab's is its off-the-record session's; the regular profile is never touched).
// Same scope, timeout and navigation guard as clearSiteDataAndReload.
- (void)clearSiteData:(NSArray<NSString*>*)types reload:(BOOL)reload completion:(void (^)(NSString* _Nullable))completion {
  auto* contents = _contents.get();
  const auto domain = SiteDataDomain(contents, /*off_the_record=*/true);
  const BOOL cookies = [types containsObject:@"cookies"], cache = [types containsObject:@"cache"];
  if (domain.empty() || (!cookies && !cache)) {
    completion(@"unavailable:This needs a live HTTP or HTTPS page."); return;
  }
  const auto document = contents->GetPrimaryMainFrame()->GetWeakDocumentPtr();
  auto weak = contents->GetWeakPtr();
  auto* partition = contents->GetPrimaryMainFrame()->GetStoragePartition();
  using Filter = content::BrowsingDataFilterBuilder;
  auto filter = Filter::Create(Filter::Mode::kDelete, Filter::OriginMatchingMode::kOriginInAllContexts);
  filter->AddRegisterableDomain(domain);
  auto finished = std::make_shared<bool>(false);
  Done done = [completion copy];
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(FROM_HERE,
    base::BindOnce([](std::shared_ptr<bool> finished, Done done) {
      if (std::exchange(*finished, true)) return;
      done(@"partial:Removal timed out; it may still finish, but the page wasn't reloaded.");
    }, finished, done), base::Seconds(30));
  const auto reload_type = cache ? content::ReloadType::BYPASSING_CACHE : content::ReloadType::NORMAL;
  auto cleared = base::BarrierClosure((cookies ? 1 : 0) + (cache ? 2 : 0), base::BindOnce(
    [](base::WeakPtr<content::WebContents> tab, content::WeakDocumentPtr document, std::shared_ptr<bool> finished,
       bool reload, content::ReloadType type, Done done) {
      if (std::exchange(*finished, true)) return;
      if (!reload) { done(nil); return; }
      if (!tab || !document.AsRenderFrameHostIfValid() ||
          document.AsRenderFrameHostIfValid() != tab->GetPrimaryMainFrame() ||
          tab->GetController().GetPendingEntry()) {
        done(@"partial:Cleared, but the tab navigated or closed, so it wasn't reloaded."); return;
      }
      tab->GetController().Reload(type, true);
      done(nil);
    }, weak, document, finished, (bool)reload, reload_type, done));
  if (cache) {
    partition->GetNetworkContext()->ClearHttpCache(base::Time(), base::Time(), filter->BuildNetworkServiceFilter(), cleared);
    partition->ClearCodeCaches(base::Time(), base::Time(), filter->BuildUrlFilter(), cleared);
  }
  if (cookies) {
    partition->ClearData(content::StoragePartition::REMOVE_DATA_MASK_COOKIES, filter.get(), {},
        filter->BuildCookieDeletionFilter(), false, base::Time(), base::Time::Max(), cleared);
  }
}
@end

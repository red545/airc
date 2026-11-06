// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#include "airc/core/airc_app_urls.h"

#import <Foundation/Foundation.h>

#include <memory>
#include <optional>

#include "base/functional/bind.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/navigation_throttle.h"
#include "content/public/browser/navigation_throttle_registry.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "airc/core/airc_browser.h"
#import "airc/core/airc_internal.h"
#import "airc/core/airc_api_internal.h"
#include "url/gurl.h"
#include "url/origin.h"
#include "net/base/schemeful_site.h"

namespace airc {

namespace {

bool IsAppURL(const GURL& url) {
  return url.SchemeIs("airc");
}

bool IsWebUIURL(const GURL& url) {
  return url.SchemeIs("chrome") || url.SchemeIs("devtools");
}

void ReportAppURLRequest(content::WebContents* contents,
                         const GURL& url,
                         bool user_gesture) {
  AircTab* tab = TabBridge::GetOrCreate(contents)->tab();
  id<AircTabDelegate> delegate = tab.delegate;
  if ([delegate respondsToSelector:@selector(tab:didRequestAppURL:userGesture:)]) {
    [delegate tab:tab
        didRequestAppURL:base::SysUTF8ToNSString(url.spec())
             userGesture:user_gesture];
  }
}

class AppSchemeThrottle : public content::NavigationThrottle {
 public:
  explicit AppSchemeThrottle(content::NavigationThrottleRegistry& registry)
      : content::NavigationThrottle(registry) {}

  ThrottleCheckResult WillStartRequest() override {
    auto* n = navigation_handle();
    auto* contents = n->GetWebContents();
    const GURL source = contents->GetLastCommittedURL();
    id<AircEngineDelegate> delegate = g_delegate;
    // Never turn a form submission (or a redirect, iframe, reload, history or
    // host load) into a GET in Peek. The app must defer opening its destination.
    if (n->IsInPrimaryMainFrame() && n->IsRendererInitiated() &&
        n->HasUserGesture() && !n->IsPost() && !n->IsSameDocument() &&
        ui::PageTransitionCoreTypeIs(n->GetPageTransition(), ui::PAGE_TRANSITION_LINK) &&
        source.SchemeIsHTTPOrHTTPS() && n->GetURL().SchemeIsHTTPOrHTTPS() &&
        net::SchemefulSite(source) != net::SchemefulSite(n->GetURL()) &&
        [delegate respondsToSelector:@selector(engine:routeLink:opener:)] &&
        [delegate engine:AircEngine.sharedEngine
            routeLink:@{@"url":base::SysUTF8ToNSString(n->GetURL().spec()),
                        @"source":@"page", @"disposition":@"current_tab", @"userGesture":@YES}
               opener:TabBridge::GetOrCreate(contents)->tab()]) {
      return CANCEL_AND_IGNORE;
    }
    return Check();
  }
  ThrottleCheckResult WillRedirectRequest() override { return Check(); }
  const char* GetNameForLogging() override { return "AircAppSchemeThrottle"; }

 private:
  ThrottleCheckResult Check() {
    content::NavigationHandle* navigation = navigation_handle();
    if (!IsAppURL(navigation->GetURL())) {
      return PROCEED;
    }
    content::WebContents* contents = navigation->GetWebContents();
    const std::optional<url::Origin>& initiator =
        navigation->GetInitiatorOrigin();
    content::NavigationEntry* committed =
        contents->GetController().GetLastCommittedEntry();
    const bool popup_start = !committed || committed->IsInitialEntry();
    if (navigation->IsInPrimaryMainFrame() && !popup_start &&
        !navigation->WasServerRedirect() && initiator &&
        IsWebUIURL(initiator->GetURL()) &&
        IsWebUIURL(contents->GetPrimaryMainFrame()->GetLastCommittedURL())) {
      base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
          FROM_HERE, base::BindOnce(
                         [](base::WeakPtr<content::WebContents> contents, GURL url,
                            bool user_gesture) {
                           if (contents) {
                             ReportAppURLRequest(contents.get(), url, user_gesture);
                           }
                         },
                         contents->GetWeakPtr(), navigation->GetURL(),
                         navigation->HasUserGesture()));
    }
    return CANCEL_AND_IGNORE;
  }
};

}

void AddAppSchemeThrottle(content::NavigationThrottleRegistry& registry) {
  registry.AddThrottle(std::make_unique<AppSchemeThrottle>(registry));
}

bool InterceptAppURL(content::WebContents* source,
                     const GURL& url,
                     bool user_gesture) {
  if (!IsAppURL(url)) {
    return false;
  }
  if (source && IsWebUIURL(source->GetLastCommittedURL())) {
    ReportAppURLRequest(source, url, user_gesture);
  }
  return true;
}

}

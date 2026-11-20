// Copyright 2026 The Airc Authors
// SPDX-License-Identifier: Apache-2.0

#include "airc/core/airc_user_agent_overrides.h"

#include <map>
#include <memory>

#include "base/supports_user_data.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/web_contents.h"
#include "net/http/http_request_headers.h"
#include "third_party/blink/public/common/user_agent/user_agent_metadata.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace airc {

namespace {

const char kOverridesKey[] = "airc-user-agent-overrides";

struct Overrides : base::SupportsUserData::Data {
  std::map<std::string, std::string> by_origin;
};

Overrides* OverridesOf(content::BrowserContext* context, bool create) {
  if (!context) {
    return nullptr;
  }
  auto* overrides = static_cast<Overrides*>(context->GetUserData(kOverridesKey));
  if (!overrides && create) {
    auto made = std::make_unique<Overrides>();
    overrides = made.get();
    context->SetUserData(kOverridesKey, std::move(made));
  }
  return overrides;
}

std::optional<std::string> Serialized(const GURL& url) {
  if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS()) {
    return std::nullopt;
  }
  url::Origin origin = url::Origin::Create(url);
  if (origin.opaque()) {
    return std::nullopt;
  }
  return origin.Serialize();
}

}  // namespace

void SetUserAgentOverride(content::BrowserContext* context, const std::string& origin, const std::string& user_agent) {
  std::optional<std::string> key = Serialized(GURL(origin));
  if (!key) {
    return;
  }
  Overrides* overrides = OverridesOf(context, !user_agent.empty());
  if (!overrides) {
    return;
  }
  if (user_agent.empty()) {
    overrides->by_origin.erase(*key);
  } else {
    overrides->by_origin[*key] = user_agent;
  }
}

std::optional<std::string> UserAgentOverrideFor(content::BrowserContext* context, const GURL& url) {
  Overrides* overrides = OverridesOf(context, false);
  if (!overrides || overrides->by_origin.empty()) {
    return std::nullopt;
  }
  std::optional<std::string> key = Serialized(url);
  if (!key) {
    return std::nullopt;
  }
  auto it = overrides->by_origin.find(*key);
  if (it == overrides->by_origin.end()) {
    return std::nullopt;
  }
  return it->second;
}

void ApplyUserAgentOverride(content::NavigationHandle* handle, bool redirect, bool* overriding) {
  if (!handle || !handle->IsInPrimaryMainFrame() || handle->IsSameDocument()) {
    return;
  }
  content::WebContents* contents = handle->GetWebContents();
  if (!contents) {
    return;
  }
  content::BrowserContext* context = contents->GetBrowserContext();
  std::optional<std::string> user_agent = UserAgentOverrideFor(context, handle->GetURL());
  if (!redirect) {
    if (user_agent) {
      contents->SetUserAgentOverride(blink::UserAgentOverride::UserAgentOnly(*user_agent), false);
      handle->SetIsOverridingUserAgent(true);
      *overriding = true;
    } else if (*overriding) {
      handle->SetIsOverridingUserAgent(false);
      *overriding = false;
    }
    return;
  }
  // A redirect off a listed origin keeps that one redirected request's header; the document it commits still has
  // the tab's override state from the start, which the next navigation resets.
  if (user_agent) {
    handle->SetRequestHeader(net::HttpRequestHeaders::kUserAgent, *user_agent);
  }
}

}  // namespace airc

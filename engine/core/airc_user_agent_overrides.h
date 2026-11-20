// Copyright 2026 The Airc Authors
// SPDX-License-Identifier: Apache-2.0

#ifndef AIRC_CORE_AIRC_USER_AGENT_OVERRIDES_H_
#define AIRC_CORE_AIRC_USER_AGENT_OVERRIDES_H_

#include <optional>
#include <string>

class GURL;

namespace content {
class BrowserContext;
class NavigationHandle;
}  // namespace content

namespace airc {

// A user agent for one exact origin of a profile (AircProfile setUserAgent:forOrigin:): the FairPlay bridge gives
// https://www.netflix.com Safari's (docs/design/fairplay-bridge.md). An empty `user_agent` removes it. Other origins,
// other profiles and WebKit pages never see it.
void SetUserAgentOverride(content::BrowserContext* context, const std::string& origin, const std::string& user_agent);
std::optional<std::string> UserAgentOverrideFor(content::BrowserContext* context, const GURL& url);

// From TabBridge, for primary main-frame, cross-document navigations. A started navigation to a listed origin makes the
// new document use the override (request headers and navigator.userAgent); one to any other origin doesn't.
// Chromium only lets a navigation's override change when it starts, so a redirect onto a listed origin
// gets the User-Agent request header instead. `overriding` is the tab's last state.
void ApplyUserAgentOverride(content::NavigationHandle* handle, bool redirect, bool* overriding);

}  // namespace airc

#endif  // AIRC_CORE_AIRC_USER_AGENT_OVERRIDES_H_

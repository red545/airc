// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#ifndef AIRC_CORE_AIRC_APP_URLS_H_
#define AIRC_CORE_AIRC_APP_URLS_H_

class GURL;

namespace content {
class NavigationThrottleRegistry;
class WebContents;
}

namespace airc {

void AddAppSchemeThrottle(content::NavigationThrottleRegistry& registry);
bool InterceptAppURL(content::WebContents* source,
                     const GURL& url,
                     bool user_gesture);

}

#endif

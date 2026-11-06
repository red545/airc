// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#ifndef AIRC_CORE_AIRC_NAVIGATION_HOLD_H_
#define AIRC_CORE_AIRC_NAVIGATION_HOLD_H_

#include <string>

class Profile;

namespace content {
class NavigationThrottleRegistry;
}

namespace airc {

void HoldNavigationsForRulesets(Profile* profile, const std::string& extension_id);

void ReleaseNavigationHold(Profile* profile, const std::string& reason);

void ReleaseNavigationHoldReady(Profile* profile);

void MaybeAddNavigationHoldThrottle(content::NavigationThrottleRegistry& registry);

}

#endif

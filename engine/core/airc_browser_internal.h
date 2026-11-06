// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#ifndef AIRC_CORE_AIRC_BROWSER_INTERNAL_H_
#define AIRC_CORE_AIRC_BROWSER_INTERNAL_H_

#include <vector>

namespace airc {

class WindowHost;

std::vector<WindowHost*>& Hosts();

}

#endif

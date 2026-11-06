// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#ifndef AIRC_CORE_AIRC_PAGE_SCRIPT_H_
#define AIRC_CORE_AIRC_PAGE_SCRIPT_H_

#include <string>

namespace content {
class RenderProcessHost;
}

namespace airc {

void SetPageScript(const std::string& script);
const std::string& GetPageScript();
void SendPageScript(content::RenderProcessHost* host);

}

#endif

// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

// Copyright 2026 Ardia. Apache-2.0.

#ifndef AIRC_CORE_AIRC_DEVTOOLS_CALL_H_
#define AIRC_CORE_AIRC_DEVTOOLS_CALL_H_

#include <optional>
#include <string>

#include "base/functional/callback.h"
#include "base/time/time.h"
#include "base/values.h"

namespace content {
class WebContents;
}

namespace airc {

using DevToolsReply = base::OnceCallback<void(std::optional<base::DictValue> result,
                                              std::optional<std::string> error)>;
void CallDevTools(content::WebContents* contents,
                  const std::string& method,
                  base::DictValue params,
                  std::optional<base::TimeDelta> timeout,
                  DevToolsReply reply);

}

#endif

// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#ifndef AIRC_CORE_AIRC_EXTENSION_DROP_H_
#define AIRC_CORE_AIRC_EXTENSION_DROP_H_

namespace content {
struct DropData;
class WebContents;
}

namespace airc {

bool InstallDroppedExtensions(content::WebContents* contents,
                              const content::DropData& drop);

}

#endif

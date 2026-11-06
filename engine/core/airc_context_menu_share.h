// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#ifndef AIRC_CORE_AIRC_CONTEXT_MENU_SHARE_H_
#define AIRC_CORE_AIRC_CONTEXT_MENU_SHARE_H_

#include <string>
#include <vector>

namespace content {
class RenderFrameHost;
struct ContextMenuParams;
}

namespace airc {

enum class ContextMenuShare { kText, kLink, kImage, kVideo, kAudio, kPage };

std::vector<ContextMenuShare> ContextMenuSharesFor(const content::ContextMenuParams& params);

std::u16string ContextMenuShareTitle(ContextMenuShare share, bool only);

std::vector<int> ContextMenuShareNeighbours(ContextMenuShare share);

void ShareFromContextMenu(content::RenderFrameHost& frame,
                          const content::ContextMenuParams& params,
                          ContextMenuShare share);

}

#endif

// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#ifndef AIRC_CORE_AIRC_EXTENSION_VIEW_H_
#define AIRC_CORE_AIRC_EXTENSION_VIEW_H_

class Browser;
class GURL;

namespace content {
class WebContents;
}

namespace gfx {
class Size;
}

namespace airc {

enum class ExtensionViewKind { kPopup, kSidePanel };

content::WebContents* OpenExtensionView(Browser* browser,
                                        const GURL& url,
                                        ExtensionViewKind kind);

bool CloseExtensionView(content::WebContents* contents);

void CloseAllExtensionViews();

gfx::Size ExtensionPopupPreferredSize(content::WebContents* contents);

void InstallActionPopupHook();

}

#endif

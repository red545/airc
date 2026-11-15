// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#ifndef AIRC_CORE_AIRC_CALL_SHARE_TARGET_H_
#define AIRC_CORE_AIRC_CALL_SHARE_TARGET_H_
class TabSharingUI;
class TabSharingInfoBarDelegate;
namespace content { class WebContents; }
namespace airc {
void CallShareChanged(TabSharingUI*, content::WebContents*, content::WebContents*, bool);
void CallShareSwitchRequested(content::WebContents* capturer);
void CallShareSwitchCancelled(content::WebContents* capturer);
TabSharingInfoBarDelegate* CallShareDelegate(content::WebContents* target,
                                            content::WebContents* capturer);
}
#endif

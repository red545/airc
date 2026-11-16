// Copyright 2026 The Airc Authors
// SPDX-License-Identifier: Apache-2.0

#ifndef AIRC_CORE_AIRC_PAGE_BUBBLE_HOOKS_H_
#define AIRC_CORE_AIRC_PAGE_BUBBLE_HOOKS_H_

class BrowserWindowInterface;

namespace content {
class WebContents;
}

namespace gfx {
class Rect;
}

namespace views {
class BubbleDialogDelegate;
}

// Bubbles Chrome anchors on its toolbar, for tabs whose window has no BrowserView (Airc's windows): the media
// remoting prompt (037-media-remoting-dialog.patch) and WebAuthn ambient sign-in (038-webauthn-ambient-dialog.patch).
// With a bubble, parents it on the window host's transparent modal parent (the one FedCM and tab-modal dialogs use)
// and anchors it at the page's top right corner, where Chrome's toolbar buttons would be. With nullptr, only answers
// whether it can. False when the tab has no Airc window host. Kept out of airc_hooks.h so the seam rebuilds only its
// users.
extern bool (*g_airc_page_bubble)(content::WebContents* contents, views::BubbleDialogDelegate* bubble);

// Bubbles aligned with Page Info (the Safety Tip on a lookalike domain, suspicious-site and wallet bubbles;
// 039-page-info-anchor.patch): bubble_anchor_util has no location bar or app menu button to anchor on without a
// BrowserView, so they use an anchor point; this one is just inside the page's top left corner, where the location
// icon would be. False when the browser has no Airc window host.
extern bool (*g_airc_page_info_anchor_rect)(BrowserWindowInterface* browser, gfx::Rect* rect);

#endif

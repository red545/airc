// Copyright 2026 The Airc Authors
// SPDX-License-Identifier: Apache-2.0

#ifndef AIRC_CORE_AIRC_FEDCM_HOOKS_H_
#define AIRC_CORE_AIRC_FEDCM_HOOKS_H_

namespace content {
class WebContents;
}

namespace views {
class View;
}

// FedCM's account chooser, loading dialog and bubble (036-fedcm-dialogs.patch): a views anchor over the tab's page
// when the tab's NSWindow is no views widget. The modal dialog parents on the anchor's widget. Kept out of
// airc_hooks.h so the seam rebuilds only its users.
extern views::View* (*g_airc_fedcm_dialog_anchor)(content::WebContents* contents);

#endif

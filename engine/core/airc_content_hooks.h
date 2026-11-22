// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#ifndef AIRC_CORE_AIRC_CONTENT_HOOKS_H_
#define AIRC_CORE_AIRC_CONTENT_HOOKS_H_

#include <stddef.h>

#include <memory>
#include <string>
#include <string_view>

#include "base/functional/callback_forward.h"
#include "extensions/common/extension_id.h"

class GURL;

namespace content {
class BrowserContext;
class DevToolsAgentHost;
class DevToolsAgentHostClient;
class DevToolsSocketFactory;
class RenderFrameHost;
class WebContents;

extern bool g_airc_opacity_from_default_color;

// Patch 042 (render_widget_host_view_mac.mm, browser_compositor_view_mac.mm):
// whether a widget's view, when it is hidden, keeps its compositor (and so the
// last frame in its CAContext) for a short while. Only for the WebContents the
// host opted in (AircTab.holdsFramesOnHide: the agent pane's live card mirrors
// its context); every other view is stock.
// The patch defines the pointer (nullptr: stock); TabBridge sets it.
class RenderWidgetHost;
extern bool (*g_airc_holds_frames_on_hide)(RenderWidgetHost* widget);
bool AircHoldsFramesOnHide(RenderWidgetHost* widget);
bool AircHoldsFramesOnHide(WebContents* contents);
void AircSetHoldsFramesOnHide(WebContents* contents, bool hold);

bool AircHasAccessedInitialMainDocument(WebContents* contents);

bool AircMainFrameHandlesEnterPictureInPicture(WebContents* contents);
}

namespace crypto::apple {
class KeychainV2;
}

class SessionID;

namespace sessions {
class LiveTab;
}

namespace extensions {
struct WebRequestInfo;
namespace declarative_net_request {
struct RequestAction;
}
}

extern int g_airc_disk_space_check_seconds;

extern bool g_airc_auto_picture_in_picture_off;
extern bool (*g_airc_auto_pip_allowed)(content::WebContents*);

// Safe Storage (patch 041, airc_safe_storage.mm). Worker thread: reads the
// "Airc Safe Storage" key into *password and returns noErr, or returns why it
// can't be used. A key that exists is never replaced; only a missing one on a
// fresh data dir is created (add-if-absent, never add-or-update). A key that
// doesn't match the one the saved data was locked with returns
// kAircSafeStorageWrongKey.
// Not an OSStatus the Security framework uses (its errors are negative): 'AIRC'.
inline constexpr int kAircSafeStorageWrongKey = 0x41495243;
extern int (*g_airc_safe_storage_read)(crypto::apple::KeychainV2* keychain,
                                       std::string_view service,
                                       std::string_view account,
                                       std::string* password);

// UI thread: the key couldn't be read. Runs `answer` with true to read it
// again, false to go on without saved passwords and cookies for this launch
// (nothing is encrypted, decrypted, deleted or re-encrypted).
extern void (*g_airc_safe_storage_unreadable)(
    int status,
    base::OnceCallback<void(bool try_again)> answer);

extern crypto::apple::KeychainV2* (*g_airc_test_keychain)();

extern bool g_airc_lazy_storage_usage;

extern bool g_airc_script_loader_ready_at_once;

extern bool g_airc_scripts_wait_at_response;

extern bool g_airc_bluetooth_poll_on_demand;

extern bool g_airc_hybrid_scan_on_demand;

void AircSetHybridUiShown(const void* model, bool shown);

extern bool (*g_airc_restricted_component_extension)(
    const extensions::ExtensionId& extension_id);

extern bool g_airc_begin_frame_bridge;

extern void (*g_airc_initial_main_document_accessed)(
    content::WebContents* contents);

extern bool (*g_airc_live_tab_skips_restore)(sessions::LiveTab* live_tab,
                                              SessionID* source);

extern int (*g_airc_permission_tab_shown)(content::WebContents*);

extern void (*g_airc_dnr_rule_matched)(
    content::BrowserContext* browser_context,
    int tab_id,
    const extensions::declarative_net_request::RequestAction& action,
    const extensions::WebRequestInfo& request);

extern void (*g_airc_dnr_rulesets_in_force)(
    content::BrowserContext* browser_context,
    const extensions::ExtensionId& extension_id,
    bool all_loaded);

extern bool (*g_airc_devtools_token_factory)(
    const content::DevToolsSocketFactory* factory);

extern bool (*g_airc_devtools_token_accepts)(
    const content::DevToolsSocketFactory* factory,
    std::string_view token);

extern void (*g_airc_devtools_token_server)(
    const content::DevToolsSocketFactory* factory,
    std::string_view browser_path,
    int port,
    size_t connections);

extern bool (*g_airc_devtools_active_target)(
    const content::DevToolsSocketFactory* factory,
    std::string_view token,
    std::string* target_id);

class AircDevToolsTokenClient {
 public:
  virtual ~AircDevToolsTokenClient() = default;
  virtual bool FilterCommand(std::string& message, std::string* reply) = 0;
  virtual bool FilterEvent(std::string& message) = 0;
  virtual bool ShouldClose() const = 0;
  virtual bool MayAttachToURL(const GURL& url, bool is_webui) = 0;
  virtual bool MayAttachToRenderFrameHost(
      content::RenderFrameHost* render_frame_host) = 0;
};

extern std::unique_ptr<AircDevToolsTokenClient> (*g_airc_devtools_token_client)(
    const content::DevToolsSocketFactory* factory,
    content::DevToolsAgentHostClient* client,
    content::DevToolsAgentHost* host);

extern bool (*g_airc_devtools_may_attach)(
    content::DevToolsAgentHostClient* root_client,
    content::DevToolsAgentHost* host);

extern bool (*g_airc_devtools_may_input)(
    content::DevToolsAgentHostClient* root_client,
    content::RenderFrameHost* frame);

#endif

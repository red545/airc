// Copyright 2026 The Airc Authors
// SPDX-License-Identifier: Apache-2.0
// Optional callbacks awaiting upstream integrations; see README.md.
#include "airc/core/airc_hooks.h"
#include "content/public/browser/web_contents.h"
#include "content/browser/web_contents/web_contents_impl.h"  // nogncheck
bool g_airc_background_instance = false;
bool (*g_airc_hidden_from_extensions)(const BrowserWindowInterface* browser) = nullptr;
bool (*g_airc_keeps_window_without_tabs)(
    const BrowserWindowInterface* browser) = nullptr;
bool (*g_airc_password_bubble)(content::WebContents* web_contents) = nullptr;
bool (*g_airc_device_chooser)(
    content::WebContents* contents,
    std::unique_ptr<permissions::ChooserController>* controller,
    base::ScopedClosureRunner* fullscreen_blocker,
    base::OnceClosure* close_closure) = nullptr;
bool (*g_airc_wants_cast_dialog)(content::WebContents* initiator) = nullptr;
bool (*g_airc_cast_dialog)(content::WebContents* initiator,
                                   media_router::MediaRouterUI* ui,
                                   base::ScopedClosureRunner* fullscreen_blocker) = nullptr;
bool (*g_airc_omits_from_session_service)(
    const BrowserWindowInterface* browser) = nullptr;
bool (*g_airc_extension_install_prompt)(
    Profile* profile,
    content::WebContents* parent,
    const extensions::InstallPromptData& prompt,
    extensions::ExtensionInstallPromptClient::DoneCallback* done_callback) = nullptr;
bool (*g_airc_extension_side_panel)(
    BrowserWindowInterface* browser_window,
    content::WebContents* web_contents,
    const extensions::ExtensionId& extension_id,
    bool open) = nullptr;
void (*g_airc_devtools_dock_changed)(BrowserWindowInterface* browser,
                                             content::WebContents* inspected,
                                             content::WebContents* devtools) = nullptr;
bool g_airc_auto_picture_in_picture_off = false;
bool (*g_airc_auto_pip_allowed)(content::WebContents*) = nullptr;
bool (*g_airc_safe_storage_key_may_be_created)() = nullptr;
void (*g_airc_safe_storage_unreadable)(int status,
                                              base::OnceClosure retry) = nullptr;
crypto::apple::KeychainV2* (*g_airc_test_keychain)() = nullptr;
bool (*g_airc_restricted_component_extension)(
    const extensions::ExtensionId& extension_id) = nullptr;
bool g_airc_begin_frame_bridge = false;
void (*g_airc_initial_main_document_accessed)(
    content::WebContents* contents) = nullptr;
bool (*g_airc_live_tab_skips_restore)(sessions::LiveTab* live_tab,
                                              SessionID* source) = nullptr;
bool (*g_airc_devtools_token_factory)(
    const content::DevToolsSocketFactory* factory) = nullptr;
bool (*g_airc_devtools_token_accepts)(
    const content::DevToolsSocketFactory* factory,
    std::string_view token) = nullptr;
void (*g_airc_devtools_token_server)(
    const content::DevToolsSocketFactory* factory,
    std::string_view browser_path,
    int port,
    size_t connections) = nullptr;
bool (*g_airc_devtools_active_target)(
    const content::DevToolsSocketFactory* factory,
    std::string_view token,
    std::string* target_id) = nullptr;
std::unique_ptr<AircDevToolsTokenClient> (*g_airc_devtools_token_client)(
    const content::DevToolsSocketFactory* factory,
    content::DevToolsAgentHostClient* client,
    content::DevToolsAgentHost* host) = nullptr;
bool (*g_airc_devtools_may_attach)(
    content::DevToolsAgentHostClient* root_client,
    content::DevToolsAgentHost* host) = nullptr;
bool (*g_airc_devtools_may_input)(
    content::DevToolsAgentHostClient* root_client,
    content::RenderFrameHost* frame) = nullptr;
namespace content {
bool AircHasAccessedInitialMainDocument(WebContents* contents) {
  return contents && static_cast<WebContentsImpl*>(contents)->HasAccessedInitialDocument();
}
bool AircMainFrameHandlesEnterPictureInPicture(WebContents*) { return false; }
}

// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#include "airc/core/airc_seams.h"

#import <AppKit/AppKit.h>

#include <memory>

#include "base/functional/callback.h"
#include "chrome/browser/lifetime/browser_shutdown.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/browser_window.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "components/permissions/chooser_controller.h"
#include "components/sessions/core/live_tab.h"
#include "components/sessions/core/session_id.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/web_contents.h"
#include "extensions/browser/extension_install_prompt_client.h"
#include "extensions/common/extension_id.h"
#include "airc/core/airc_hooks.h"
#include "airc/core/airc_browser.h"
#include "airc/core/airc_cast_dialog.h"
#include "airc/core/airc_browser_window.h"
#include "airc/core/airc_device_chooser.h"
#include "airc/core/airc_extension_shortcuts.h"
#include "airc/core/airc_extension_view.h"
#include "airc/core/airc_installed_bubble.h"
#import "airc/core/airc_api_internal.h"
#import "airc/core/airc_internal.h"

namespace airc {

namespace {

bool HandlePasswordBubble(content::WebContents* web_contents) {
  WindowHost* host = WindowHost::ForContents(web_contents);
  return host && host->OfferPasswordSave(web_contents);
}

bool HandleExtensionSidePanel(BrowserWindowInterface* browser_window,
                              content::WebContents* web_contents,
                              const extensions::ExtensionId& extension_id,
                              bool open) {
  content::WebContents* contents = web_contents;
  if (!contents && browser_window && browser_window->GetActiveTabInterface()) {
    contents = browser_window->GetActiveTabInterface()->GetContents();
  }
  if (!WindowHost::ForContents(contents)) {
    return false;
  }
  return HostExtensionSidePanel(contents, extension_id, open);
}

bool LiveTabSkipsRestore(sessions::LiveTab* live_tab, SessionID* source) {
  int32_t source_id = 0;
  if (!live_tab || !IsTemporaryTabId(live_tab->GetSessionID().id(), &source_id)) {
    return false;
  }
  if (source && source_id > 0) {
    *source = SessionID::FromSerializedValue(source_id);
  }
  return true;
}

bool OmitsFromSessionService(const BrowserWindowInterface* browser) {
  return AircBrowserWindow::IsOurs(browser);
}

bool IsHiddenFromExtensions(const BrowserWindowInterface* browser) {
  WindowHost* host = WindowHost::ForBrowser(browser);
  return host && host->internal();
}

bool KeepsWindowWithoutTabs(const BrowserWindowInterface* browser) {
  WindowHost* host = WindowHost::ForBrowser(browser);
  return host && !host->closing() && !browser_shutdown::IsTryingToQuit();
}

std::unique_ptr<BrowserWebContentsDelegate> CreateWebContentsDelegate(
    BrowserWindowInterface* browser,
    ExclusiveAccessManager& exclusive_access_manager,
    chrome::BrowserCommandController& command_controller,
    UnloadController& unload_controller,
    web_app::AppBrowserController* app_browser_controller,
    BrowserWindow& window,
    DesktopBrowserWindowCapabilities& capabilities,
    BrowserUiController& browser_ui_controller) {
  AircBrowserWindow* ours = AircBrowserWindow::FromWindow(&window);
  if (!ours) {
    return nullptr;
  }
  ours->Register(browser);
  return std::make_unique<AircWebContentsDelegate>(
      browser, exclusive_access_manager, command_controller, unload_controller,
      app_browser_controller, window, capabilities, browser_ui_controller,
      ours->host_weak());
}

const char* BrowserTypeName(BrowserWindowInterface::Type type) {
  switch (type) {
    case BrowserWindowInterface::TYPE_NORMAL:
      return "normal";
    case BrowserWindowInterface::TYPE_POPUP:
      return "popup";
    case BrowserWindowInterface::TYPE_DEVTOOLS:
      return "devtools";
    case BrowserWindowInterface::TYPE_PICTURE_IN_PICTURE:
      return "picture_in_picture";
    default:
      return "app";
  }
}

BrowserWindow* WindowForChromeBrowser(Browser* browser) {
  if (AircBrowserWindow::IsOurs(browser) ||
      browser->GetType() == BrowserWindowInterface::TYPE_PICTURE_IN_PICTURE) {
    return nullptr;
  }
  AircWindow* window = [g_delegate
      engineWindowForNewBrowserOfProfile:[AircProfile
                                             wrapperFor:browser->GetProfile()]
                                    type:@(BrowserTypeName(browser->GetType()))];
  WindowHost* host = window.host;
  return host ? host->HostChromeBrowser(browser) : nullptr;
}

bool IsReservedAccelerator(const ui::Accelerator& accelerator) {
  NSEvent* event = NSApp.currentEvent;
  return event.type == NSEventTypeKeyDown &&
         ExtensionShortcuts::AcceleratorFor(event) == accelerator &&
         [g_delegate engineIsReservedKeyEvent:event];
}

bool IsHistoryEligible(content::WebContents* contents) {
  WindowHost* host = WindowHost::ForContents(contents);
  return !host || !host->internal();
}

void DevToolsDockChanged(BrowserWindowInterface* browser,
                         content::WebContents* inspected,
                         content::WebContents* devtools) {
  if (WindowHost* host = WindowHost::ForBrowser(browser)) {
    host->DevToolsDockChanged(inspected, devtools);
  }
}

}

void InstallChromeHooks() {
  g_airc_browser_window_factory = &WindowForChromeBrowser;
  g_airc_reserved_accelerator = &IsReservedAccelerator;
  g_airc_reserved_global_accelerator = &IsReservedGlobalAccelerator;
  g_airc_global_shortcuts_resumed = &GlobalShortcutsResumed;
  g_airc_history_eligible = &IsHistoryEligible;
  InstallRuleMatchedHook();
  InstallExtensionInstalledHook();
  InstallActionPopupHook();
  g_airc_password_bubble = &HandlePasswordBubble;
  g_airc_extension_install_prompt = &HostExtensionInstallPrompt;
  g_airc_device_chooser = &HandleDeviceChooser;
  g_airc_wants_cast_dialog = &WantsCastDialog;
  g_airc_cast_dialog = &HandleCastDialog;
  g_airc_extension_side_panel = &HandleExtensionSidePanel;
  g_airc_hidden_from_extensions = &IsHiddenFromExtensions;
  g_airc_keeps_window_without_tabs = &KeepsWindowWithoutTabs;
  g_airc_devtools_dock_changed = &DevToolsDockChanged;
  g_airc_create_web_contents_delegate = &CreateWebContentsDelegate;
  g_airc_initial_main_document_accessed = &InitialMainDocumentAccessed;
  g_airc_live_tab_skips_restore = &LiveTabSkipsRestore;
  g_airc_omits_from_session_service = &OmitsFromSessionService;
  g_airc_viewless_browsers = true;
}

}

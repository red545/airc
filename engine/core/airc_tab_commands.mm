// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#import "airc/core/public/Airc.h"

#include <optional>
#include <sstream>
#include <string>
#include <utility>

#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/metrics/user_metrics.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/sys_string_conversions.h"
#include "base/time/time.h"
#include "base/values.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "chrome/browser/devtools/devtools_contents_resizing_strategy.h"
#include "chrome/browser/devtools/devtools_toggle_action.h"
#include "chrome/browser/devtools/devtools_window.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_commands.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/tab_contents/core_tab_helper.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/webauthn/authenticator_request_scheduler.h"
#include "chrome/browser/webauthn/chrome_authenticator_request_delegate.h"
#include "chrome/common/content_restriction.h"
#include "chrome/common/pref_names.h"
#include "components/blocked_content/popup_blocker_tab_helper.h"
#include "components/content_settings/core/browser/host_content_settings_map.h"
#include "components/policy/core/common/policy_pref_names.h"
#include "components/prefs/pref_service.h"
#include "components/web_modal/web_contents_modal_dialog_manager.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/web_contents.h"
#include "content/public/common/url_utils.h"
#include "pdf/buildflags.h"
#include "printing/buildflags/buildflags.h"
#include "ui/gfx/geometry/rect.h"
#if BUILDFLAG(ENABLE_PDF)
#include "chrome/browser/pdf/pdf_extension_util.h"
#include "pdf/pdf_features.h"
#endif
#if BUILDFLAG(ENABLE_PRINTING)
#include "chrome/browser/printing/print_view_manager_common.h"
#endif
#if BUILDFLAG(ENABLE_PRINT_PREVIEW)
#include "chrome/browser/printing/print_preview_dialog_controller.h"
#endif
#include "airc/core/airc_browser.h"
#include "airc/core/airc_launch_switches.h"
#include "airc/core/airc_host_visibility.h"
#include "base/dcheck_is_on.h"
#include "ui/views/cocoa/native_widget_mac_ns_window_host.h"
#include "components/remote_cocoa/app_shim/native_widget_ns_window_bridge.h"
#include "ui/views/widget/widget.h"
#include "ui/views/widget/widget_delegate.h"
#include "ui/views/window/dialog_delegate.h"
#include "airc/core/airc_devtools_call.h"
#include "airc/core/airc_developer_commands.h"
#import "airc/core/airc_internal.h"
#import "airc/core/airc_tab_internal.h"

namespace {

std::optional<bool> RunPageCommand(content::WebContents* contents, int command) {
  Profile* profile = Profile::FromBrowserContext(contents->GetBrowserContext());
  PrefService* prefs = profile->GetPrefs();
  CoreTabHelper* core = CoreTabHelper::FromWebContents(contents);
  const int restrictions = core ? core->content_restrictions() : 0;
  switch (command) {
#if BUILDFLAG(ENABLE_PRINTING)
    case IDC_PRINT:
    case IDC_BASIC_PRINT: {
      auto* dialogs = web_modal::WebContentsModalDialogManager::FromWebContents(contents);
      const bool can_print = prefs->GetBoolean(prefs::kPrintingEnabled) && !contents->IsCrashed() &&
                             !(dialogs && dialogs->IsDialogActive()) &&
                             !(restrictions & CONTENT_RESTRICTION_PRINT);
      bool preview = false;
#if BUILDFLAG(ENABLE_PRINT_PREVIEW)
      auto* previews = printing::PrintPreviewDialogController::GetInstance();
      preview = previews && (previews->GetPrintPreviewForContents(contents) ||
                             previews->is_creating_print_preview_dialog());
#endif
      if (!can_print && !(command == IDC_BASIC_PRINT && preview &&
                          prefs->GetBoolean(prefs::kPrintingEnabled))) {
        return false;
      }
      if (command == IDC_PRINT) {
        printing::StartPrint(contents, prefs->GetBoolean(prefs::kPrintPreviewDisabled),
                             false);
      } else {
        printing::StartBasicPrint(contents);
      }
      return true;
    }
#endif
    case IDC_SAVE_PAGE: {
      PrefService* local_state = g_browser_process->local_state();
      content::NavigationEntry* entry = contents->GetController().GetLastCommittedEntry();
      if ((local_state && !local_state->GetBoolean(prefs::kAllowFileSelectionDialogs)) ||
          static_cast<policy::DownloadRestriction>(
              prefs->GetInteger(policy::policy_prefs::kDownloadRestrictions)) ==
              policy::DownloadRestriction::ALL_FILES ||
          (restrictions & CONTENT_RESTRICTION_SAVE) ||
          (entry && !content::IsSavableURL(entry->GetURL()))) {
        return false;
      }
      base::RecordAction(base::UserMetricsAction("SavePage"));
#if BUILDFLAG(ENABLE_PDF)
      if (contents->GetContentsMimeType() == "application/pdf" &&
          chrome_pdf::features::IsOopifPdfEnabled() &&
          pdf_extension_util::MaybeDispatchSaveEvent(contents->GetPrimaryMainFrame())) {
        return true;
      }
#endif
      contents->OnSavePage();
      return true;
    }
    case IDC_DEV_TOOLS_CONSOLE:
    case IDC_DEV_TOOLS_INSPECT:
      DevToolsWindow::OpenDevToolsWindow(
          contents,
          command == IDC_DEV_TOOLS_CONSOLE ? DevToolsToggleAction::ShowConsolePanel()
                                           : DevToolsToggleAction::Inspect(),
          DevToolsOpenedByAction::kMainMenuOrMainShortcut);
      return true;
    case IDC_DEV_TOOLS_TOGGLE: {
      DevToolsWindow* tools = DevToolsWindow::GetInstanceForInspectedWebContents(contents);
      if (tools && tools->IsDocked()) {
        if (content::WebContents* docked = DevToolsWindow::GetInTabWebContents(contents, nullptr)) {
          docked->DispatchBeforeUnload(false);
        }
      } else {
        DevToolsWindow::OpenDevToolsWindow(contents, DevToolsToggleAction::Show(),
                                           DevToolsOpenedByAction::kMainMenuOrMainShortcut);
      }
      return true;
    }
    default:
      return std::nullopt;
  }
}

}

@implementation AircTab (Commands)

- (void)openBlockedPopup:(NSString*)popupId always:(BOOL)always {
  if (airc::DeferWhileTabStripNotifies(^{
        [self openBlockedPopup:popupId always:always];
      })) {
    return;
  }
  if (!_contents) {
    return;
  }
  auto* popups = blocked_content::PopupBlockerTabHelper::FromWebContents(_contents);
  int id_number = 0;
  if (!popups || !base::StringToInt(base::SysNSStringToUTF8(popupId), &id_number) ||
      !popups->GetBlockedPopupRequests().contains(id_number)) {
    return;
  }
  if (always) {
    HostContentSettingsMapFactory::GetForProfile(_contents->GetBrowserContext())
        ->SetContentSettingDefaultScope(_contents->GetLastCommittedURL(), GURL(),
                                        ContentSettingsType::POPUPS,
                                        CONTENT_SETTING_ALLOW);
  }
  airc::WindowHost* host = airc::WindowHost::ForContents(_contents);
  std::optional<base::AutoReset<airc::OpenOrigin>> pending;
  if (host) {
    pending.emplace(host->ScopedPendingOpen(
        {WindowOpenDisposition::NEW_FOREGROUND_TAB, _contents->GetWeakPtr()}));
  }
  popups->ShowBlockedPopup(id_number, WindowOpenDisposition::NEW_FOREGROUND_TAB);
}

- (BOOL)executeChromeCommand:(int)command {
  if (airc::DeferWhileTabStripNotifies(^{
        [self executeChromeCommand:command];
      })) {
    return YES;
  }
  if (!_contents) {
    return NO;
  }
  BrowserWindowInterface* browser =
      GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(_contents);
  if (!browser) {
    return NO;
  }
  TabStripModel* model = browser->GetTabStripModel();
  const int index = model->GetIndexOfWebContents(_contents);
  const int active = model->active_index();
  if (index == TabStripModel::kNoTab) {
    return NO;
  }
  if (index == active) {
    return chrome::ExecuteCommand(browser, command);
  }
  if (std::optional<bool> ran = RunPageCommand(_contents, command)) {
    return *ran;
  }
  if (command == IDC_CARET_BROWSING_TOGGLE) {
    return chrome::ExecuteCommand(browser, command);
  }
  return NO;
}

- (BOOL)cancelModalDialogForTesting {
  return [self respondToModalDialogForTesting:NO];
}

- (BOOL)respondToModalDialogForTesting:(BOOL)accept {
  if (!airc::TestFlag("modalDialogs") || !_contents) return NO;
  auto* host = airc::WindowHost::ForContents(_contents);
  if (!host) return NO;
  auto* parent = views::NativeWidgetMacNSWindowHost::GetFromNativeView(host->GetHostView());
  if (parent) for (auto* child : parent->children()) {
    auto* widget = child->GetWidget();
    auto* delegate = widget ? widget->widget_delegate() : nullptr;
    if (delegate && delegate->GetModalType() == ui::mojom::ModalType::kChild &&
        delegate->AsDialogDelegate()) {
      if (accept) delegate->AsDialogDelegate()->AcceptDialog();
      else delegate->AsDialogDelegate()->CancelDialog();
      return YES;
    }
  }
  return NO;
}

- (BOOL)selectHybridMechanismForTesting {
  if (!airc::TestFlag("modalDialogs") || !_contents) return NO;
  auto* request = AuthenticatorRequestScheduler::GetRequestDelegate(_contents);
  if (!request) return NO;
  auto* model = request->dialog_model();
  if (model->step() != AuthenticatorRequestDialogModel::Step::kMechanismSelection)
    return NO;
  for (const auto& mechanism : model->mechanisms) {
    if (std::holds_alternative<AuthenticatorRequestDialogModel::Mechanism::Hybrid>(mechanism.type)) {
      // Copy before invoking: selection can synchronously replace the model UI.
      auto callback = mechanism.callback;
      callback.Run();
      return YES;
    }
  }
  return NO;
}

- (NSDictionary*)modalDialogStateForTesting {
  if (!airc::TestFlag("modalDialogs") || !_contents) return @{};
  auto* host = airc::WindowHost::ForContents(_contents);
  if (!host) return @{};
  auto* parent = views::NativeWidgetMacNSWindowHost::GetFromNativeView(host->GetHostView());
  NSMutableArray* dialogs = [NSMutableArray array];
  if (parent) for (auto* child : parent->children()) {
    auto* widget = child->GetWidget();
    if (!widget || !widget->widget_delegate() ||
        widget->widget_delegate()->GetModalType() != ui::mojom::ModalType::kChild) continue;
    auto* bridge = child->GetInProcessNSWindowBridge();
    NSWindow* window = widget->GetNativeWindow().GetNativeNSWindow();
    [dialogs addObject:@{@"windowNumber":@(window.windowNumber),
        @"registeredParentMatchesHost":@(child->parent() == parent),
        @"childModal":@YES, @"widgetVisible":@(widget->IsVisible()),
        @"nativeVisible":@(window.visible),
        @"nativeParent":@(window.parentWindow.windowNumber),
        @"nativeMovable":@(window.movable),
        @"nativeBackgroundDrag":@(window.movableByWindowBackground),
        @"contentCanMoveWindow":@(window.contentView.mouseDownCanMoveWindow),
        @"widgetClosed":@(widget->IsClosed()),
        @"nativeAnimationsDisabled":@(window.animationBehavior == NSWindowAnimationBehaviorNone),
        @"wantsVisible":@(bridge && bridge->wants_to_be_visible()),
        @"frame":NSStringFromRect(window.frame)}];
  }
  std::ostringstream step;
  if (auto* request = AuthenticatorRequestScheduler::GetRequestDelegate(_contents))
    step << request->dialog_model()->step();
  NSWindow* native_parent = host->GetHostView().GetNativeNSView().window;
  return @{@"webauthnStep":base::SysUTF8ToNSString(step.str()),
      @"mainFrame":NSStringFromRect(host->ns_window().frame),
      @"mainVisible":@(host->ns_window().visible),
      @"modalParentFrame":NSStringFromRect(native_parent.frame),
      @"modalParentLinked":@(native_parent.parentWindow == host->ns_window()),
      @"modalParentVisible":@(native_parent.visible),
      @"mainOnActiveSpace":@(host->ns_window().onActiveSpace),
      @"dchecks":@(DCHECK_IS_ON()), @"registeredHost":@(parent != nullptr),
      @"hostViewInAppWindow":@(host->host_view().window == host->ns_window()),
      @"tabVisible":@(airc::ShownByHost(_contents).value_or(false)), @"dialogs":dialogs};
}

- (void)devToolsCall:(NSString*)method
              params:(NSDictionary*)params
             timeout:(NSTimeInterval)timeout
          completion:(void (^)(NSDictionary* result, NSString* error))completion {
  base::DictValue dict;
  if (params.count) {
    NSData* data = [NSJSONSerialization dataWithJSONObject:params options:0 error:nil];
    std::optional<base::DictValue> parsed =
        data ? base::JSONReader::ReadDict(
                   std::string_view(static_cast<const char*>(data.bytes), data.length),
                   base::JSON_PARSE_RFC)
             : std::nullopt;
    if (!parsed) {
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(nil, @"params aren't JSON");
      });
      return;
    }
    dict = std::move(*parsed);
  }
  airc::CallDevTools(
      _contents, base::SysNSStringToUTF8(method), std::move(dict),
      timeout > 0 ? std::optional<base::TimeDelta>(base::Seconds(timeout)) : std::nullopt,
      base::BindOnce(
          [](void (^completion)(NSDictionary*, NSString*),
             std::optional<base::DictValue> result, std::optional<std::string> error) {
            if (!result) {
              completion(nil, base::SysUTF8ToNSString(error.value_or("error")));
              return;
            }
            std::optional<std::string> json = base::WriteJson(*result);
            NSData* data = json ? [NSData dataWithBytes:json->data() length:json->size()] : nil;
            id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]
                             : nil;
            if (![object isKindOfClass:NSDictionary.class]) {
              completion(nil, @"the reply isn't JSON");
              return;
            }
            completion(object, nil);
          },
          completion));
}

- (void)showDevTools {
  if (_contents) {
    DevToolsWindow::OpenDevToolsWindow(_contents, DevToolsToggleAction::Show(),
                                       DevToolsOpenedByAction::kUnknown);
  }
}

- (void)closeDevTools {
  airc::CloseDeveloperTools(_contents);
}

- (void)attachDevToolsToView:(NSView*)host {
  content::WebContents* tools = _contents ? DevToolsWindow::GetInTabWebContents(_contents, nullptr) : nullptr;
  if (tools) [airc::TabBridge::GetOrCreate(tools)->tab() attachToView:host];
}

- (void)copyDevToolsPicture:(NSTimeInterval)timeout
                completion:(void (^)(CGImageRef _Nullable))completion {
  content::WebContents* tools = _contents ? DevToolsWindow::GetInTabWebContents(_contents, nullptr) : nullptr;
  if (tools) [airc::TabBridge::GetOrCreate(tools)->tab() copyPicture:timeout completion:completion];
  else completion(nullptr);
}

- (NSView*)devToolsView {
  if (!_contents) {
    return nil;
  }
  content::WebContents* devtools =
      DevToolsWindow::GetInTabWebContents(_contents, nullptr);
  return devtools ? devtools->GetNativeView().GetNativeNSView() : nil;
}

- (void)devToolsLayoutForSize:(NSSize)size
                     devTools:(NSRect*)devToolsFrame
                         page:(NSRect*)pageFrame {
  DevToolsContentsResizingStrategy strategy;
  gfx::Rect devtools_bounds, page_bounds;
  gfx::Rect container(0, 0, size.width, size.height);
  if (_contents && DevToolsWindow::GetInTabWebContents(_contents, &strategy)) {
    ApplyDevToolsContentsResizingStrategy(strategy, container, &devtools_bounds,
                                          &page_bounds);
  } else {
    page_bounds = container;
  }
  if (devToolsFrame) {
    *devToolsFrame = devtools_bounds.ToCGRect();
  }
  if (pageFrame) {
    *pageFrame = page_bounds.ToCGRect();
  }
}

@end

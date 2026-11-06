// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#include "airc/core/airc_modal_dialog_host.h"

#import <AppKit/AppKit.h>

#include <algorithm>
#include "base/functional/bind.h"
#include "chrome/browser/chrome_browser_application_mac.h"
#include "components/constrained_window/constrained_window_views.h"
#include "components/javascript_dialogs/app_modal_dialog_manager.h"
#include "components/javascript_dialogs/app_modal_dialog_view.h"
#include "components/strings/grit/components_strings.h"
#include "ui/base/l10n/l10n_util.h"
#include "ui/views/controls/label.h"
#include "ui/views/widget/widget_observer.h"
#include "base/task/single_thread_task_runner.h"
#include "ui/views/window/dialog_delegate.h"
#include "ui/strings/grit/ui_strings.h"

#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface_iterator.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/web_contents.h"
#include "airc/core/airc_browser.h"

namespace airc {

namespace {

// Chrome's macOS beforeunload fallback is an app-modal NSAlert. Keep its
// controller/queue semantics, but put host-owned tabs through the same constrained
// dialog path as WebAuthn so switching tabs hides the prompt with its page.
class BeforeUnloadDialog : public views::DialogDelegate,
                           public javascript_dialogs::AppModalDialogView,
                           public views::WidgetObserver {
 public:
  explicit BeforeUnloadDialog(
      std::unique_ptr<javascript_dialogs::AppModalDialogController> controller)
      : controller_(std::move(controller)) {
    SetOwnershipOfNewWidget(views::Widget::InitParams::CLIENT_OWNS_WIDGET);
    SetModalType(ui::mojom::ModalType::kChild);
    SetTitle(controller_->title());
    SetButtonLabel(ui::mojom::DialogButton::kOk, l10n_util::GetStringUTF16(
        controller_->is_reload() ? IDS_BEFORERELOAD_MESSAGEBOX_OK_BUTTON_LABEL
                                 : IDS_BEFOREUNLOAD_MESSAGEBOX_OK_BUTTON_LABEL));
    SetButtonLabel(ui::mojom::DialogButton::kCancel,
                   l10n_util::GetStringUTF16(IDS_APP_CANCEL));
    SetDefaultButton(static_cast<int>(ui::mojom::DialogButton::kCancel));
    auto* label = SetContentsView(std::make_unique<views::Label>(controller_->message_text()));
    label->SetMultiLine(true);
    label->SetHorizontalAlignment(gfx::ALIGN_LEFT);
    label->SizeToFit(360);
    set_margins(gfx::Insets(20));
    SetAcceptCallback(base::BindOnce([](BeforeUnloadDialog* self) {
      self->controller_->OnAccept(std::u16string(), false);
    }, base::Unretained(this)));
    SetCancelCallback(base::BindOnce([](BeforeUnloadDialog* self) {
      chrome_browser_application_mac::CancelTerminate();
      self->controller_->OnCancel(false);
    }, base::Unretained(this)));
    SetCloseCallback(base::BindOnce([](BeforeUnloadDialog* self) {
      self->controller_->OnClose();
    }, base::Unretained(this)));
  }
  ~BeforeUnloadDialog() override {
    if (widget_) widget_->RemoveObserver(this);
    widget_.reset();
    controller_->OnClose();
  }
  void OnWidgetClosing(views::Widget* widget) override {
    widget->RemoveObserver(this);
    base::SingleThreadTaskRunner::GetCurrentDefault()->DeleteSoon(FROM_HERE, this);
  }
  void ShowAppModalDialog() override {
    widget_ = constrained_window::ShowWebModalDialogViewsOwned(
        this, controller_->web_contents(), views::Widget::InitParams::CLIENT_OWNS_WIDGET);
    widget_->AddObserver(this);
  }
  void ActivateAppModalDialog() override { GetWidget()->Activate(); }
  void CloseAppModalDialog() override { GetWidget()->Close(); }
  void AcceptAppModalDialog() override { AcceptDialog(); }
  void CancelAppModalDialog() override { CancelDialog(); }
  bool IsShowing() const override { return GetWidget() && GetWidget()->IsVisible(); }
 private:
  std::unique_ptr<javascript_dialogs::AppModalDialogController> controller_;
  std::unique_ptr<views::Widget> widget_;
};

int g_dialog_host_observers = 0;
id g_frame_change_observer = nil;

}

void InstallModalDialogHosting() {
  auto* manager = javascript_dialogs::AppModalDialogManager::GetInstance();
  auto fallback = *manager->view_factory();
  manager->SetNativeDialogFactory(base::BindRepeating(
      [](javascript_dialogs::AppModalDialogManager::AppModalViewFactory fallback,
         std::unique_ptr<javascript_dialogs::AppModalDialogController> controller)
          -> javascript_dialogs::AppModalDialogView* {
        if (controller->is_before_unload_dialog() &&
            WindowHost::ForContents(controller->web_contents()))
          return new BeforeUnloadDialog(std::move(controller));
        return fallback.Run(std::move(controller));
      }, std::move(fallback)));
}

gfx::Rect PageRectInHostView(NSView* host_view, content::WebContents* contents) {
  if (!host_view) {
    return gfx::Rect();
  }
  NSRect bounds = host_view.bounds;
  NSRect page = bounds;
  NSView* view = contents ? contents->GetNativeView().GetNativeNSView() : nil;
  if (view && view.window == host_view.window && view.superview &&
      [view isDescendantOf:host_view.window.contentView]) {
    page = NSIntersectionRect([view convertRect:view.bounds toView:host_view],
                              bounds);
    if (NSIsEmptyRect(page)) {
      page = bounds;
    }
  }
  const CGFloat top = host_view.isFlipped ? NSMinY(page)
                                          : NSHeight(bounds) - NSMaxY(page);
  return gfx::Rect(NSMinX(page), top, NSWidth(page), NSHeight(page));
}

gfx::Point DialogPositionInHostView(NSView* host_view,
                                    const gfx::Rect& page,
                                    const gfx::Size& size) {
  const int host_width = host_view ? NSWidth(host_view.bounds) : page.right();
  int x = page.x() + (page.width() - size.width()) / 2;
  x = std::min(x, host_width - size.width());
  x = std::max(x, 0);
  return gfx::Point(x, page.y());
}

bool WindowIsForeground(NSWindow* window) {
  if (!window || !NSApp.isActive) {
    return false;
  }
  if (NSApp.mainWindow == window) {
    return true;
  }
  for (NSWindow* key = NSApp.keyWindow; key;
       key = key.parentWindow ?: key.sheetParent) {
    if (key == window) {
      return true;
    }
  }
  return false;
}

void DialogHostObserverAdded() {
  if (++g_dialog_host_observers != 1 || g_frame_change_observer) {
    return;
  }
  g_frame_change_observer = [NSNotificationCenter.defaultCenter
      addObserverForName:NSViewFrameDidChangeNotification
                  object:nil
                   queue:nil
              usingBlock:^(NSNotification* notification) {
                NSView* view = notification.object;
                if (![view isKindOfClass:[NSView class]]) {
                  return;
                }
                if (WindowHost* host = WindowHost::ForNSWindow(view.window)) {
                  host->ScheduleDialogPositionUpdate();
                }
              }];
}

void DialogHostObserverRemoved() {
  if (g_dialog_host_observers == 0 || --g_dialog_host_observers != 0 ||
      !g_frame_change_observer) {
    return;
  }
  [NSNotificationCenter.defaultCenter removeObserver:g_frame_change_observer];
  g_frame_change_observer = nil;
}

AircTabDialogHost::AircTabDialogHost(content::WebContents* contents)
    : content::WebContentsUserData<AircTabDialogHost>(*contents) {}

AircTabDialogHost::~AircTabDialogHost() {
  CloseDialogs();
  for ([[maybe_unused]] auto& observer : observers_) {
    DialogHostObserverRemoved();
  }
}

void AircTabDialogHost::CloseDialogs() {
  for (auto& observer : observers_) {
    observer.OnHostDestroying();
  }
}

WindowHost* AircTabDialogHost::window_host() const {
  auto* tab = tabs::TabInterface::MaybeGetFromContents(
      const_cast<content::WebContents*>(&GetWebContents()));
  return tab ? WindowHost::ForBrowser(tab->GetBrowserWindowInterface())
             : nullptr;
}

gfx::NativeView AircTabDialogHost::GetHostView() const {
  WindowHost* host = window_host();
  return host ? host->GetHostView() : gfx::NativeView();
}

gfx::Point AircTabDialogHost::GetDialogPosition(const gfx::Size& size) {
  WindowHost* host = window_host();
  NSView* host_view = host ? host->host_view() : nil;
  return DialogPositionInHostView(
      host_view, PageRectInHostView(host_view, &GetWebContents()), size);
}

bool AircTabDialogHost::ShouldActivateDialog() const {
  auto* tab = tabs::TabInterface::MaybeGetFromContents(
      const_cast<content::WebContents*>(&GetWebContents()));
  WindowHost* host = window_host();
  return tab && tab->GetBrowserWindowInterface() && host &&
         GetLastActiveBrowserWindowInterfaceWithAnyProfile() ==
             tab->GetBrowserWindowInterface() &&
         WindowIsForeground(host->ns_window());
}

gfx::Size AircTabDialogHost::GetMaximumDialogSize() {
  WindowHost* host = window_host();
  return PageRectInHostView(host ? host->host_view() : nil, &GetWebContents())
      .size();
}

void AircTabDialogHost::AddObserver(web_modal::ModalDialogHostObserver* observer) {
  if (observers_.HasObserver(observer)) {
    return;
  }
  observers_.AddObserver(observer);
  DialogHostObserverAdded();
}

void AircTabDialogHost::RemoveObserver(
    web_modal::ModalDialogHostObserver* observer) {
  if (!observers_.HasObserver(observer)) {
    return;
  }
  observers_.RemoveObserver(observer);
  DialogHostObserverRemoved();
}

void AircTabDialogHost::NotifyPositionRequiresUpdate() {
  observers_.Notify(
      &web_modal::ModalDialogHostObserver::OnPositionRequiresUpdate);
}

WEB_CONTENTS_USER_DATA_KEY_IMPL(AircTabDialogHost);

}

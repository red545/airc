// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#include "airc/core/airc_browser.h"

#import <AppKit/AppKit.h>

#include <map>

#include "base/auto_reset.h"
#include "base/functional/bind.h"
#include "base/no_destructor.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface_iterator.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "content/public/browser/web_contents.h"
#include "airc/core/airc_browser_window.h"
#include "airc/core/airc_modal_dialog_host.h"
#include "ui/views/widget/widget.h"
#include "ui/views/cocoa/native_widget_mac_ns_window_host.h"
#include "ui/gfx/mac/coordinate_conversion.h"

namespace airc {

namespace {

// P02b: set while NotifyPositionRequiresUpdate re-anchors the modal parent after a frame change. With no dialog
// showing, the parent then follows the page lazily, once the page has kept its frame for kLazyAnchorDelay: every
// SetBounds makes its bridge wait in the next CA commit for this invisible widget's compositor
// (CATransactionCoordinator), and the page's frame changes on every frame of a sidebar slide.
bool g_lazy_modal_parent_bounds = false;
constexpr base::TimeDelta kLazyAnchorDelay = base::Milliseconds(150);

// The latest lazy re-anchor asked for, per host (a newer request supersedes older ones).
std::map<const WindowHost*, uint64_t>& LazyAnchorGenerations() {
  static base::NoDestructor<std::map<const WindowHost*, uint64_t>> generations;
  return *generations;
}

// A dialog (or any child window) shows over the modal parent: it must follow the page on every frame.
bool ModalParentShowsChild(views::Widget* parent) {
  NSWindow* window = parent->GetNativeWindow().GetNativeNSWindow();
  for (NSWindow* child in window.childWindows) {
    if (child.visible) {
      return true;
    }
  }
  if (auto* host = views::NativeWidgetMacNSWindowHost::GetFromNativeView(parent->GetNativeView())) {
    for (auto* child : host->children()) {
      if (views::Widget* widget = child->GetWidget(); widget && widget->IsVisible()) {
        return true;
      }
    }
  }
  return false;
}

}  // namespace

gfx::NativeView WindowHost::GetHostView() const {
  if (!externally_hosted()) return gfx::NativeView(host_view_);
  // A plain AppKit NSView has no NativeWidgetMacNSWindowHost. kChild dialogs
  // require that bridge both during InitModalType and later reparent/show calls.
  const_cast<WindowHost*>(this)->UpdateModalParent();
  return modal_parent_->GetNativeView();
}

void WindowHost::UpdateModalParent() {
  if (!externally_hosted()) return;
  if (!modal_parent_) {
    modal_parent_ = std::make_unique<views::Widget>();
    views::Widget::InitParams params(
        views::Widget::InitParams::CLIENT_OWNS_WIDGET,
        views::Widget::InitParams::TYPE_WINDOW_FRAMELESS);
    params.name = "AircModalParent";
    params.opacity = views::Widget::InitParams::WindowOpacity::kTranslucent;
    params.activatable = views::Widget::InitParams::Activatable::kNo;
    params.accept_events = false;
    params.bounds = gfx::Rect(0, 0, 1, 1);
    modal_parent_->Init(std::move(params));
    NSWindow* parent = modal_parent_->GetNativeWindow().GetNativeNSWindow();
    parent.backgroundColor = NSColor.clearColor;
    parent.opaque = NO;
    parent.hasShadow = NO;
    parent.collectionBehavior = NSWindowCollectionBehaviorTransient |
        NSWindowCollectionBehaviorIgnoresCycle |
        NSWindowCollectionBehaviorFullScreenAuxiliary;
  }
  // Constrained-window positioning asks for this parent after creating the
  // dialog and before showing it. Keep hosted child dialogs on the ordinary
  // asynchronous CloseWindow path: the custom Cocoa hide animator can stall in
  // optimized DCHECK-off builds with our external AppKit parent, leaving a
  // logically closed widget visible forever (and later dialogs behind it).
  // Disabling native animations also overrides the manager's ANIMATE_HIDE;
  // forcing CloseNow from a Cancel callback would instead risk reentrant deletion.
  auto* native_parent = views::NativeWidgetMacNSWindowHost::GetFromNativeView(
      modal_parent_->GetNativeView());
  if (native_parent) {
    for (auto* child : native_parent->children()) {
      auto* widget = child->GetWidget();
      if (widget && widget->widget_delegate() &&
          widget->widget_delegate()->GetModalType() == ui::mojom::ModalType::kChild)
        widget->SetVisibilityChangedAnimationsEnabled(false);
    }
  }
  // The app creates the first Browser before it lays the host view out, so the
  // view can still be zero-sized or windowless here. Mac widgets reject empty
  // frames (DCHECK in SetBoundsInScreen); the host view's frame notification
  // re-anchors the parent once it has a real size.
  NSRect rect = host_view_.window
      ? [ns_window() convertRectToScreen:
            [host_view_ convertRect:host_view_.bounds toView:nil]]
      : NSZeroRect;
  if (NSWidth(rect) < 1 || NSHeight(rect) < 1) {
    modal_parent_->Hide();
    return;
  }
  const gfx::Rect bounds = gfx::ScreenRectFromNSRect(rect);
  const gfx::Rect current = modal_parent_->GetWindowBoundsInScreen();
  if (g_lazy_modal_parent_bounds && current != bounds && current.width() > 1 &&
      current.height() > 1 && !ModalParentShowsChild(modal_parent_.get())) {
    // A frame change with no dialog: anchor once the page is at rest. A dialog about to show re-anchors at once
    // (GetHostView), and one showing follows every frame (the branch below).
    const uint64_t generation = ++LazyAnchorGenerations()[this];
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
        FROM_HERE,
        base::BindOnce(
            [](base::WeakPtr<WindowHost> host, uint64_t generation) {
              if (!host) {
                return;
              }
              auto it = LazyAnchorGenerations().find(host.get());
              if (it == LazyAnchorGenerations().end() || it->second != generation) {
                return;
              }
              LazyAnchorGenerations().erase(it);
              host->UpdateModalParent();
            },
            GetWeakPtr(), generation),
        kLazyAnchorDelay);
  } else {
    LazyAnchorGenerations().erase(this);
    modal_parent_->SetBounds(bounds);
  }
  // Match NativeWidgetNSWindowBridge::OrderChildren: adding a Cocoa child
  // to an off-Space window can switch Spaces. Our external NSWindow has no
  // Chromium bridge, so we must enforce this guard for the extra parent too.
  // Keeping the proxy hidden also makes step-transition Widget::Show() defer
  // its children instead of activating an unparented dialog on another Space.
  if (ns_window().visible && ns_window().onActiveSpace && !host_view_.hidden) {
    if (!modal_parent_->IsVisible()) modal_parent_->ShowInactive();
    NSWindow* parent = modal_parent_->GetNativeWindow().GetNativeNSWindow();
    // orderOut (including the initial hidden state) removes Cocoa child links.
    if (parent.parentWindow != ns_window())
      [ns_window() addChildWindow:parent ordered:NSWindowAbove];
  } else {
    modal_parent_->Hide();
  }
}

namespace {

content::WebContents* ActiveContentsOf(const WindowHost* host) {
  Browser* browser = host->active_profile()
                         ? host->ExistingBrowserFor(host->active_profile())
                         : nullptr;
  return browser ? browser->GetTabStripModel()->GetActiveWebContents()
                 : nullptr;
}

}

gfx::Point WindowHost::GetDialogPosition(const gfx::Size& size) {
  return DialogPositionInHostView(
      host_view_, PageRectInHostView(host_view_, ActiveContentsOf(this)),
      size);
}

bool WindowHost::ShouldActivateDialog() const {
  BrowserWindowInterface* last =
      GetLastActiveBrowserWindowInterfaceWithAnyProfile();
  return last && ForBrowser(last) == this &&
         IsActiveBrowser(static_cast<Browser*>(last)) &&
         WindowIsForeground(ns_window());
}

gfx::Size WindowHost::GetMaximumDialogSize() {
  return PageRectInHostView(host_view_, ActiveContentsOf(this)).size();
}

void WindowHost::AddObserver(web_modal::ModalDialogHostObserver* observer) {
  if (modal_observers_.HasObserver(observer)) {
    return;
  }
  modal_observers_.AddObserver(observer);
  DialogHostObserverAdded();
}

void WindowHost::RemoveObserver(web_modal::ModalDialogHostObserver* observer) {
  if (!modal_observers_.HasObserver(observer)) {
    return;
  }
  modal_observers_.RemoveObserver(observer);
  DialogHostObserverRemoved();
}

void WindowHost::NotifyPositionRequiresUpdate() {
  dialog_position_update_scheduled_ = false;
  if (modal_parent_) {
    base::AutoReset<bool> lazy(&g_lazy_modal_parent_bounds, true);
    UpdateModalParent();
  }
  modal_observers_.Notify(
      &web_modal::ModalDialogHostObserver::OnPositionRequiresUpdate);
  for (Browser* browser : browsers()) {
    TabStripModel* tabs = browser->GetTabStripModel();
    for (int i = 0; i < tabs->count(); ++i) {
      if (auto* host = AircTabDialogHost::FromWebContents(tabs->GetWebContentsAt(i))) {
        host->NotifyPositionRequiresUpdate();
      }
    }
  }
}

void WindowHost::ScheduleDialogPositionUpdate() {
  if (dialog_position_update_scheduled_) {
    return;
  }
  dialog_position_update_scheduled_ = true;
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&WindowHost::NotifyPositionRequiresUpdate,
                                GetWeakPtr()));
}

void WindowHost::OnWidgetBoundsChanged(views::Widget* widget,
                                       const gfx::Rect& new_bounds) {
  ScheduleDialogPositionUpdate();
  for (Browser* browser : browsers()) {
    if (AircBrowserWindow* window = AircBrowserWindow::FromWindow(BrowserWindow::FromBrowser(browser))) {
      window->RepositionExclusiveAccessBubble();
    }
  }
}

}

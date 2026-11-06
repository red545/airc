// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#include "airc/core/airc_browser_window.h"
#include "ui/gfx/mac/coordinate_conversion.h"
#import <AppKit/AppKit.h>

#include "base/functional/bind.h"
#include "base/task/single_thread_task_runner.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/exclusive_access/exclusive_access_manager.h"
#include "chrome/browser/ui/exclusive_access/fullscreen_controller.h"
#include "chrome/browser/ui/views/exclusive_access/exclusive_access_bubble_views.h"
#include "content/public/browser/render_widget_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/web_contents.h"
#include "airc/core/airc_browser.h"
#include "ui/base/accelerators/accelerator.h"
#include "ui/events/event_constants.h"
#include "ui/events/keycodes/keyboard_codes.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/views/widget/widget.h"

namespace airc {

ExclusiveAccessContext* AircBrowserWindow::GetExclusiveAccessContext() {
  return this;
}

Profile* AircBrowserWindow::GetProfile() {
  return browser_ ? browser_->GetProfile() : nullptr;
}

void AircBrowserWindow::EnterFullscreen(const url::Origin& origin,
                                      ExclusiveAccessBubbleType bubble_type,
                                      FullscreenTabParams fullscreen_tab_params) {
  tab_fullscreen_ = true;
  base::WeakPtr<AircBrowserWindow> self = weak_factory_.GetWeakPtr();
  ReportFullscreenTab();
  if (self) {
    PostWindowFullscreenStateChanged();
  }
}

void AircBrowserWindow::ExitFullscreen() {
  tab_fullscreen_ = false;
  ReportFullscreenTab();
}

void AircBrowserWindow::PostWindowFullscreenStateChanged() {
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(
                     [](base::WeakPtr<AircBrowserWindow> window) {
                       ExclusiveAccessManager* manager =
                           window ? window->GetExclusiveAccessManager()
                                  : nullptr;
                       if (manager && window->tab_fullscreen_) {
                         manager->fullscreen_controller()
                             ->WindowFullscreenStateChanged();
                       }
                     },
                     weak_factory_.GetWeakPtr()));
}

void AircBrowserWindow::UpdateExclusiveAccessBubble(
    const ExclusiveAccessBubbleParams& params,
    ExclusiveAccessBubbleHideCallback first_hide_callback) {
  base::WeakPtr<AircBrowserWindow> self = weak_factory_.GetWeakPtr();
  ReportFullscreenTab();
  if (!self) {
    return;
  }
  const bool can_show = host_ && host_->widget() && browser_ &&
                        GetExclusiveAccessManager();
  const bool should_close_bubble =
      !can_show ||
      (!params.has_download && params.type == EXCLUSIVE_ACCESS_BUBBLE_TYPE_NONE);
  if (should_close_bubble) {
    if (first_hide_callback) {
      std::move(first_hide_callback)
          .Run(ExclusiveAccessBubbleHideReason::kNotShown);
    }
    if (!exclusive_access_bubble_ ||
        exclusive_access_bubble_destruction_task_id_) {
      return;
    }
    exclusive_access_bubble_->HideImmediately();
    exclusive_access_bubble_destruction_task_id_ =
        exclusive_access_bubble_task_tracker_.PostTask(
            base::SingleThreadTaskRunner::GetCurrentDefault().get(), FROM_HERE,
            base::BindOnce(&AircBrowserWindow::DestroyAnyExclusiveAccessBubble,
                           weak_factory_.GetWeakPtr()));
    return;
  }
  if (exclusive_access_bubble_) {
    if (exclusive_access_bubble_destruction_task_id_) {
      exclusive_access_bubble_task_tracker_.TryCancel(
          *exclusive_access_bubble_destruction_task_id_);
      exclusive_access_bubble_destruction_task_id_.reset();
    }
    exclusive_access_bubble_->Update(params, std::move(first_hide_callback));
    return;
  }
  exclusive_access_bubble_ = std::make_unique<ExclusiveAccessBubbleViews>(
      this, params, std::move(first_hide_callback));
}

void AircBrowserWindow::OnExclusiveAccessUserInput() {
  if (exclusive_access_bubble_) {
    exclusive_access_bubble_->OnUserInput();
  }
}

ExclusiveAccessManager* AircBrowserWindow::GetExclusiveAccessManager() {
  return browser_ ? ExclusiveAccessManager::From(browser_)
                  : nullptr;
}

ui::AcceleratorProvider* AircBrowserWindow::GetAcceleratorProvider() {
  return this;
}

bool AircBrowserWindow::GetAcceleratorForCommandId(
    int command_id,
    ui::Accelerator* accelerator) const {
  if (command_id != IDC_FULLSCREEN) {
    return false;
  }
  *accelerator =
      ui::Accelerator(ui::VKEY_F, ui::EF_CONTROL_DOWN | ui::EF_COMMAND_DOWN);
  return true;
}

gfx::NativeView AircBrowserWindow::GetBubbleParentView() const {
  return host_ ? gfx::NativeView(host_->host_view())
                                  : gfx::NativeView();
}

gfx::Rect AircBrowserWindow::GetClientAreaBoundsInScreen() const {
  return host_
             ? gfx::ScreenRectFromNSRect([host_->ns_window() convertRectToScreen:
                   [host_->host_view() convertRect:host_->host_view().bounds toView:nil]])
             : gfx::Rect();
}

bool AircBrowserWindow::IsImmersiveModeEnabled() const {
  return false;
}

gfx::Rect AircBrowserWindow::GetTopContainerBoundsInScreen() {
  return gfx::Rect();
}

void AircBrowserWindow::RepositionExclusiveAccessBubble() {
  if (exclusive_access_bubble_) {
    exclusive_access_bubble_->RepositionIfVisible();
  }
}

void AircBrowserWindow::DestroyAnyExclusiveAccessBubble() {
  exclusive_access_bubble_.reset();
  exclusive_access_bubble_destruction_task_id_.reset();
}

void AircBrowserWindow::ReportFullscreenTab() {
  ExclusiveAccessManager* manager =
      browser_ ? ExclusiveAccessManager::From(browser_) : nullptr;
  FullscreenController* controller =
      manager ? manager->fullscreen_controller() : nullptr;
  content::WebContents* now = controller && controller->IsTabFullscreen()
                                  ? controller->exclusive_access_tab()
                                  : nullptr;
  content::WebContents* was = fullscreen_tab_.get();
  if (now == was) {
    return;
  }
  fullscreen_tab_ = now ? now->GetWeakPtr() : nullptr;
  if (!host_ || !browser_) {
    return;
  }
  base::WeakPtr<content::WebContents> entering = fullscreen_tab_;
  if (was) {
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(
                       [](base::WeakPtr<content::WebContents> left) {
                         content::RenderWidgetHostView* view =
                             left ? left->GetRenderWidgetHostView() : nullptr;
                         if (view && !left->IsFullscreen()) {
                           view->GetRenderWidgetHost()
                               ->SynchronizeVisualProperties();
                         }
                       },
                       was->GetWeakPtr()));
    host_->FullscreenChanged(was, false);
  }
  if (content::WebContents* contents = entering.get();
      contents && contents == fullscreen_tab_.get() && host_) {
    host_->FullscreenChanged(contents, true);
  }
}

bool AircBrowserWindow::IsExclusiveAccessBubbleDisplayed() const {
  return exclusive_access_bubble_ && (exclusive_access_bubble_->IsShowing() ||
                                      exclusive_access_bubble_->IsVisible());
}

content::WebContents* AircBrowserWindow::GetWebContentsForExclusiveAccess() {
  return browser_ ? browser_->GetTabStripModel()->GetActiveWebContents()
                  : nullptr;
}

bool AircBrowserWindow::CanUserEnterFullscreen() const {
  return true;
}

bool AircBrowserWindow::CanUserExitFullscreen() const {
  return true;
}

std::string AircBrowserWindow::GetWorkspace() const {
  return std::string();
}

bool AircBrowserWindow::IsVisibleOnAllWorkspaces() const {
  return false;
}

}

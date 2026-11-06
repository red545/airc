// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#ifndef AIRC_CORE_AIRC_MODAL_DIALOG_HOST_H_
#define AIRC_CORE_AIRC_MODAL_DIALOG_HOST_H_

#include "base/observer_list.h"
#include "components/web_modal/web_contents_modal_dialog_host.h"
#include "content/public/browser/web_contents_user_data.h"
#include "ui/gfx/geometry/point.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/geometry/size.h"

@class NSView;
@class NSWindow;

namespace content {
class WebContents;
}

namespace airc {

class WindowHost;

void InstallModalDialogHosting();

gfx::Rect PageRectInHostView(NSView* host_view, content::WebContents* contents);
gfx::Point DialogPositionInHostView(NSView* host_view,
                                    const gfx::Rect& page,
                                    const gfx::Size& size);

bool WindowIsForeground(NSWindow* window);
void DialogHostObserverAdded();
void DialogHostObserverRemoved();

class AircTabDialogHost : public web_modal::WebContentsModalDialogHost,
                        public content::WebContentsUserData<AircTabDialogHost> {
 public:
  AircTabDialogHost(const AircTabDialogHost&) = delete;
  AircTabDialogHost& operator=(const AircTabDialogHost&) = delete;
  ~AircTabDialogHost() override;

  gfx::NativeView GetHostView() const override;
  gfx::Point GetDialogPosition(const gfx::Size& size) override;
  bool ShouldActivateDialog() const override;
  gfx::Size GetMaximumDialogSize() override;
  void AddObserver(web_modal::ModalDialogHostObserver* observer) override;
  void RemoveObserver(web_modal::ModalDialogHostObserver* observer) override;
  void NotifyPositionRequiresUpdate() override;
  void CloseDialogs();

 private:
  friend class content::WebContentsUserData<AircTabDialogHost>;
  explicit AircTabDialogHost(content::WebContents* contents);

  WindowHost* window_host() const;

  base::ObserverList<web_modal::ModalDialogHostObserver> observers_;
  WEB_CONTENTS_USER_DATA_KEY_DECL();
};

}

#endif

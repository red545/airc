// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#import "airc/core/public/Airc.h"
#import "airc/core/airc_tab_internal.h"

#include <algorithm>
#include <cmath>
#include <memory>
#include "base/files/file_path.h"
#include "base/functional/bind.h"
#include "base/location.h"
#include "base/strings/sys_string_conversions.h"
#include "base/supports_user_data.h"
#include "base/task/thread_pool.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/tab_contents/core_tab_helper.h"
#include "chrome/common/content_restriction.h"
#include "chrome/common/pref_names.h"
#include "components/download/public/common/download_item.h"
#include "components/policy/core/common/policy_pref_names.h"
#include "components/prefs/pref_service.h"
#include "components/viz/common/frame_sinks/copy_output_result.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/download_item_utils.h"
#include "content/public/browser/download_manager.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/save_page_type.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/common/url_utils.h"
#include "content/public/common/url_constants.h"
#include "skia/ext/image_operations.h"
#include "ui/gfx/image/image.h"

namespace {
const char kPageSave[] = "airc.page-save";
using SaveCompletion = void (^)(NSString*);
void Reply(SaveCompletion completion, NSString* error) {
  dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
}

// Owned by WebContents; observes the profile's save-package download before
// SavePage creates it (creation can be asynchronous). No upstream hook needed.
class PageSave final : public base::SupportsUserData::Data,
                       public content::WebContentsObserver,
                       public content::DownloadManager::Observer,
                       public download::DownloadItem::Observer {
 public:
  explicit PageSave(content::WebContents* contents)
      : content::WebContentsObserver(contents) {}
  ~PageSave() override { Finish(@"cancelled"); }
  bool busy() const { return completion_ != nil; }
  void Start(const base::FilePath& path, content::SavePageType type,
             SaveCompletion completion) {
    path_ = path;
    completion_ = [completion copy];
    manager_ = web_contents()->GetBrowserContext()->GetDownloadManager();
    manager_->AddObserver(this);
    if (!web_contents()->SavePage(path, base::FilePath(path.RemoveExtension().value() + "_files"), type))
      Finish(@"failed:save could not start");
  }
  void OnDownloadCreated(content::DownloadManager*, download::DownloadItem* item) override {
    if (!busy() || item_ || !item->IsSavePackageDownload() ||
        content::DownloadItemUtils::GetWebContents(item) != web_contents() ||
        item->GetTargetFilePath() != path_) return;
    item_ = item;
    item_->AddObserver(this);
    OnDownloadUpdated(item);
  }
  void OnDownloadUpdated(download::DownloadItem* item) override {
    switch (item->GetState()) {
      case download::DownloadItem::COMPLETE: Finish(nil); break;
      case download::DownloadItem::CANCELLED:
        Finish(item->GetLastReason() == download::DOWNLOAD_INTERRUPT_REASON_USER_CANCELED
                   ? @"cancelled" : @"failed:save cancelled or write failure");
        break;
      case download::DownloadItem::INTERRUPTED: Finish(@"failed:write failure"); break;
      case download::DownloadItem::IN_PROGRESS: break;
      case download::DownloadItem::MAX_DOWNLOAD_STATE: Finish(@"failed:invalid download state"); break;
    }
  }
  void OnDownloadDestroyed(download::DownloadItem*) override { Finish(@"cancelled"); }
  void ManagerGoingDown(content::DownloadManager*) override { Finish(@"cancelled"); }
  void WebContentsDestroyed() override { Finish(@"cancelled"); }
  void PrimaryPageChanged(content::Page&) override { Finish(@"cancelled"); }
 private:
  void Finish(NSString* error) {
    if (item_) { item_->RemoveObserver(this); item_ = nullptr; }
    if (manager_) { manager_->RemoveObserver(this); manager_ = nullptr; }
    if (completion_) {
      SaveCompletion done = completion_;
      completion_ = nil;
      Reply(done, error);
    }
  }
  raw_ptr<content::DownloadManager> manager_ = nullptr;
  raw_ptr<download::DownloadItem> item_ = nullptr;
  base::FilePath path_;
  SaveCompletion __strong completion_ = nil;
};
}

@implementation AircTab (Exports)
- (BOOL)canSavePage {
  if (!_contents || _contents->IsCrashed() ||
      !_contents->GetPrimaryMainFrame()->IsRenderFrameLive() ||
      !_contents->IsSavable() || !content::IsSavableURL(_contents->GetLastCommittedURL())) return NO;
  // Chromium's scheme list includes WebUI/devtools, but this host API promises
  // document exports, not serialization of privileged browser UI.
  const GURL& url = _contents->GetLastCommittedURL();
  if (url.SchemeIs(content::kChromeUIScheme) ||
      url.SchemeIs(content::kChromeUIUntrustedScheme) ||
      url.SchemeIs(content::kChromeDevToolsScheme)) return NO;
  auto* local = g_browser_process->local_state();
  auto* prefs = Profile::FromBrowserContext(_contents->GetBrowserContext())->GetPrefs();
  auto* core = CoreTabHelper::FromWebContents(_contents);
  return (!local || local->GetBoolean(prefs::kAllowFileSelectionDialogs)) &&
      static_cast<policy::DownloadRestriction>(prefs->GetInteger(policy::policy_prefs::kDownloadRestrictions)) !=
          policy::DownloadRestriction::ALL_FILES &&
      !(core && (core->content_restrictions() & CONTENT_RESTRICTION_SAVE));
}

- (void)savePageTo:(NSString*)path format:(AircSavePageFormat)format
        completion:(void (^)(NSString*))completion {
  if (!self.canSavePage) { Reply(completion, @"notSavable"); return; }
  if (format < AircSavePageFormatHTML || format > AircSavePageFormatMHTML) {
    Reply(completion, @"failed:invalid format"); return;
  }
  if (!path.isAbsolutePath || [path rangeOfString:@"\0"].location != NSNotFound) {
    Reply(completion, @"failed:invalid path"); return;
  }
  auto* save = static_cast<PageSave*>(_contents->GetUserData(kPageSave));
  if (!save) {
    auto owned = std::make_unique<PageSave>(_contents);
    save = owned.get();
    _contents->SetUserData(kPageSave, std::move(owned));
  }
  if (save->busy()) { Reply(completion, @"busy"); return; }
  save->Start(base::FilePath(base::SysNSStringToUTF8(path)),
              static_cast<content::SavePageType>(format), completion);
}

- (void)snapshotWithMaxSize:(CGSize)size completion:(void (^)(NSImage*))completion {
  auto* view = _contents ? _contents->GetRenderWidgetHostView() : nullptr;
  if (!std::isfinite(size.width) || !std::isfinite(size.height) ||
      size.width < 1 || size.height < 1 || !view || _contents->IsCrashed() ||
      !_contents->GetPrimaryMainFrame()->IsRenderFrameLive() || !view->IsSurfaceAvailableForCopy()) {
    dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
    return;
  }
  // Never show, repaint or wake a hidden page. Existing surfaces may be stale.
  // Cap allocation even if a caller accidentally passes a huge requested size.
  const int width = std::min(size.width, 4096.0);
  const int height = std::min(size.height, 4096.0);
  view->CopyFromSurface(gfx::Rect(), gfx::Size(), base::Milliseconds(500),
      base::BindOnce(^(const content::CopyFromSurfaceResult& result) {
        SkBitmap bitmap = result.has_value() ? result->bitmap : SkBitmap();
        base::ThreadPool::PostTask(FROM_HERE, {base::TaskPriority::USER_VISIBLE},
            base::BindOnce(^{
              SkBitmap scaled;
              if (!bitmap.drawsNothing()) {
                const double scale = std::min({1.0, double(width) / bitmap.width(), double(height) / bitmap.height()});
                scaled = skia::ImageOperations::Resize(bitmap, skia::ImageOperations::RESIZE_GOOD,
                    std::max(1, int(bitmap.width() * scale)), std::max(1, int(bitmap.height() * scale)));
              }
              content::GetUIThreadTaskRunner({})->PostTask(FROM_HERE, base::BindOnce(^{
                completion(scaled.drawsNothing() ? nil : gfx::Image::CreateFrom1xBitmap(scaled).ToNSImage());
              }));
            }));
      }));
}
@end

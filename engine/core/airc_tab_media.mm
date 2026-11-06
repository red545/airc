// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#import "airc/core/public/Airc.h"

#include <optional>
#include <string>

#include "base/functional/bind.h"
#include "base/location.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "chrome/browser/media/webrtc/media_capture_devices_dispatcher.h"
#include "chrome/browser/media/webrtc/media_stream_capture_indicator.h"
#include "chrome/browser/picture_in_picture/picture_in_picture_window_manager.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/exclusive_access/exclusive_access_manager.h"
#include "chrome/browser/ui/tab_sharing/tab_sharing_infobar_delegate.h"
#include "components/infobars/content/content_infobar_manager.h"
#include "components/infobars/core/infobar.h"
#include "components/viz/common/frame_sinks/copy_output_result.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_process_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_media_capture_id.h"
#include "third_party/skia/include/core/SkBitmap.h"
#include "third_party/skia/include/core/SkColorSpace.h"
#include "third_party/skia/include/core/SkData.h"
#include "third_party/skia/include/encode/SkICC.h"
#include "third_party/skia/modules/skcms/skcms.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/geometry/size.h"
#include "url/gurl.h"
#include "airc/core/airc_cast_dialog.h"
#include "airc/core/airc_content_hooks.h"
#include "airc/core/airc_device_chooser.h"
#include "airc/core/airc_host_visibility.h"
#include "airc/core/airc_page_channel.h"
#include "airc/core/airc_picture_in_picture.h"
#import "airc/core/airc_api_internal.h"
#import "airc/core/airc_internal.h"
#import "airc/core/airc_tab_internal.h"

using airc::NS;

namespace {

CGImageRef CreatePicture(const SkBitmap& bitmap) {
  if (bitmap.drawsNothing() || bitmap.bytesPerPixel() != 4 ||
      (bitmap.colorType() != kBGRA_8888_SkColorType &&
       bitmap.colorType() != kRGBA_8888_SkColorType)) {
    return nullptr;
  }
  const bool opaque = bitmap.alphaType() == kOpaque_SkAlphaType;
  const CGBitmapInfo info =
      bitmap.colorType() == kBGRA_8888_SkColorType
          ? kCGBitmapByteOrder32Little |
                (opaque ? kCGImageAlphaNoneSkipFirst : kCGImageAlphaPremultipliedFirst)
          : kCGBitmapByteOrder32Big |
                (opaque ? kCGImageAlphaNoneSkipLast : kCGImageAlphaPremultipliedLast);
  CGColorSpaceRef space = nullptr;
  if (SkColorSpace* sk = bitmap.colorSpace()) {
    skcms_TransferFunction fn;
    skcms_Matrix3x3 toXYZD50;
    if (sk->isNumericalTransferFn(&fn) && sk->toXYZD50(&toXYZD50)) {
      if (sk_sp<SkData> icc = SkWriteICCProfile(fn, toXYZD50)) {
        CFDataRef data = CFDataCreate(nullptr, icc->bytes(), icc->size());
        space = CGColorSpaceCreateWithICCData(data);
        CFRelease(data);
      }
    }
  }
  if (!space) {
    space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  }
  CFDataRef pixels = CFDataCreate(nullptr, static_cast<const UInt8*>(bitmap.getPixels()),
                                  bitmap.computeByteSize());
  CGDataProviderRef provider = CGDataProviderCreateWithCFData(pixels);
  CGImageRef image = CGImageCreate(bitmap.width(), bitmap.height(), 8, 32, bitmap.rowBytes(),
                                   space, info, provider, nullptr, false,
                                   kCGRenderingIntentDefault);
  CGDataProviderRelease(provider);
  CFRelease(pixels);
  CGColorSpaceRelease(space);
  return image;
}

TabSharingInfoBarDelegate* TabSharingDelegateFor(content::WebContents* contents,
                                                 content::WebContents* capturer) {
  // Upstream 156 keeps the capture-session identity private. The old fork's
  // capturer_id() accessor is not available. Never guess from a tab's infobar:
  // that could redirect a different capture session to this page.
  return nullptr;
}

}

@implementation AircTab (Media)

- (NSString*)mediaCaptureSourceId {
  content::RenderFrameHost* frame =
      _contents ? _contents->GetPrimaryMainFrame() : nullptr;
  if (!frame || !frame->IsRenderFrameLive()) {
    return nil;
  }
  return NS(content::WebContentsMediaCaptureId(frame->GetProcess()->GetDeprecatedID(),
                                               frame->GetRoutingID())
                .ToString());
}

- (void)copyPicture:(NSTimeInterval)timeout completion:(void (^)(CGImageRef))completion {
  content::RenderWidgetHostView* view =
      _contents ? _contents->GetRenderWidgetHostView() : nullptr;
  if (!view || !view->IsSurfaceAvailableForCopy()) {
    completion(nullptr);
    return;
  }
  void (^done)(CGImageRef) = [completion copy];
  view->CopyFromSurface(
      gfx::Rect(), gfx::Size(), base::Seconds(timeout),
      base::BindOnce(^(const content::CopyFromSurfaceResult& result) {
        CGImageRef image = result.has_value() ? CreatePicture(result->bitmap) : nullptr;
        content::GetUIThreadTaskRunner({})->PostTask(FROM_HERE, base::BindOnce(^{
                                                       done(image);
                                                       if (image) {
                                                         CGImageRelease(image);
                                                       }
                                                     }));
      }));
}

- (BOOL)stopCapture {
  if (!_contents) {
    return NO;
  }
  scoped_refptr<MediaStreamCaptureIndicator> indicator =
      MediaCaptureDevicesDispatcher::GetInstance()->GetMediaStreamCaptureIndicator();
  const bool capturing = indicator->IsCapturingTab(_contents) ||
                         indicator->IsCapturingWindow(_contents) ||
                         indicator->IsCapturingDisplay(_contents);
  indicator->StopMediaCapturing(_contents,
                                MediaStreamCaptureIndicator::MediaType::kDisplayMedia);
  return capturing;
}

- (void)noteShownByHost:(BOOL)shown {
  if (_contents) {
    airc::NoteTabShownByHost(_contents, shown);
  }
}

- (void)exitFullscreen {
  if (_contents && _contents->IsFullscreen()) {
    _contents->ExitFullscreen(true);
  }
}

- (void)exitExclusiveAccess {
  if (!_contents) {
    return;
  }
  BrowserWindowInterface* browser =
      GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(_contents);
  ExclusiveAccessManager* manager =
      browser ? ExclusiveAccessManager::From(browser) : nullptr;
  if (manager) {
    manager->OnTabDeactivated(_contents);
  }
}

- (void)tracePictureInPicture:(NSString*)line withInputs:(BOOL)withInputs {
  if (!airc::PictureInPictureTracing()) {
    return;
  }
  if (withInputs && _contents) {
    airc::TraceAutoPictureInPictureInputs(_contents, line.UTF8String);
  } else {
    airc::TracePictureInPicture(base::SysNSStringToUTF8(line));
  }
}

- (BOOL)showCastDialog {
  return airc::ShowCastDialog(_contents);
}

- (BOOL)devShowBluetoothChooser:(BOOL)unauthorized {
  return airc::ShowTestBluetoothChooser(_contents, unauthorized);
}

- (BOOL)canShareThisTabInsteadFor:(AircTab*)capturer {
  TabSharingInfoBarDelegate* sharing =
      TabSharingDelegateFor(_contents, capturer.contents);
  return sharing &&
         (sharing->GetButtons() & TabSharingInfoBarDelegate::kShareThisTabInstead) &&
         sharing->IsButtonEnabled(TabSharingInfoBarDelegate::kShareThisTabInstead);
}

- (BOOL)shareThisTabInsteadFor:(AircTab*)capturer {
  if (![self canShareThisTabInsteadFor:capturer]) {
    return NO;
  }
  TabSharingDelegateFor(_contents, capturer.contents)->ShareThisTabInstead();
  return YES;
}

- (void)enterPictureInPictureForClickAt:(NSTimeInterval)clickTime
                             completion:(void (^)(NSString* route, BOOL opened))completion {
  if (!_contents) {
    completion(@"none", NO);
    return;
  }
  const airc::PictureInPictureRoute route =
      airc::PageChannel::GetOrCreate(_contents)->EnterPictureInPictureForClick(
          clickTime > 0 ? std::optional<base::TimeTicks>(base::TimeTicks() +
                                                         base::Seconds(clickTime))
                        : std::nullopt,
          base::BindOnce(
              [](void (^completion)(NSString*, BOOL), bool opened) {
                completion(@"element", opened);
              },
              completion));
  if (route == airc::PictureInPictureRoute::kMediaSession) {
    completion(@"session", NO);
  } else if (route == airc::PictureInPictureRoute::kNone) {
    completion(@"none", NO);
  }
}

- (void)enterPictureInPictureForHost:(void (^)(NSString*, BOOL))completion {
  // Host action time fences navigation races just as native context-menu actions
  // do. No page script or web-facing API can invoke this trusted entry point.
  [self enterPictureInPictureForClickAt:
      (base::TimeTicks::Now() - base::TimeTicks()).InSecondsF()
                             completion:completion];
}

- (void)exitPictureInPicture {
  if (!_contents) {
    return;
  }
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(
                     [](base::WeakPtr<content::WebContents> contents) {
                       PictureInPictureWindowManager* manager =
                           PictureInPictureWindowManager::GetInstance();
                       if (contents && manager->GetWebContents() == contents.get()) {
                         manager->ExitPictureInPicture();
                       }
                     },
                     _contents->GetWeakPtr()));
}

@end

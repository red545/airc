// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#import "airc/core/public/Airc.h"

#include <cmath>
#include <optional>
#include <string>

#include "base/functional/bind.h"
#include "base/strings/sys_string_conversions.h"
#include "components/zoom/page_zoom.h"
#include "components/zoom/zoom_controller.h"
#include "content/public/browser/web_contents.h"
#include "content/public/common/page_zoom.h"
#include "third_party/blink/public/common/page/page_zoom.h"
#include "third_party/skia/include/core/SkColor.h"
#include "airc/core/airc_browser.h"
#include "airc/core/airc_contents_background.h"
#include "airc/core/airc_page_channel.h"
#import "airc/core/airc_api_internal.h"
#import "airc/core/airc_internal.h"
#import "airc/core/airc_tab_internal.h"

using airc::NS;

@implementation AircTab (Page)

- (BOOL)independentZoom { return _independentZoom; }
- (void)setIndependentZoom:(BOOL)independent {
  _independentZoom = independent;
  if (_contents) if (auto* zoom = zoom::ZoomController::FromWebContents(_contents))
    zoom->SetZoomMode(independent ? zoom::ZoomController::ZOOM_MODE_ISOLATED
                                  : zoom::ZoomController::ZOOM_MODE_DEFAULT);
}

- (double)zoomFactor {
  return _contents ? blink::ZoomLevelToZoomFactor(
                         zoom::ZoomController::GetZoomLevelForWebContents(_contents))
                   : 1;
}

- (void)setZoomFactor:(double)zoomFactor {
  if (!_contents || zoomFactor <= 0) {
    return;
  }
  if (_independentZoom) self.independentZoom = YES;
  if (auto* zoom = zoom::ZoomController::FromWebContents(_contents)) {
    zoom->SetZoomLevel(blink::ZoomFactorToZoomLevel(zoomFactor));
  }
}

- (void)zoomStep:(int)direction {
  if (_contents) {
    if (_independentZoom) self.independentZoom = YES;
    zoom::PageZoom::Zoom(_contents, direction > 0   ? content::PAGE_ZOOM_IN
                                    : direction < 0 ? content::PAGE_ZOOM_OUT
                                                    : content::PAGE_ZOOM_RESET);
  }
}

- (double)pinchScale {
  return _contents ? airc::TabBridge::GetOrCreate(_contents)->pinch_scale() : 1;
}

- (NSColor*)pageBackgroundColor {
  return _pageBackgroundColor;
}

- (NSString*)pageColor {
  if (!_contents) {
    return nil;
  }
  auto* channel = airc::PageChannel::FromWebContents(_contents);
  return channel && !channel->page_color().empty()
             ? base::SysUTF8ToNSString(channel->page_color())
             : nil;
}

- (void)setPageColor:(NSString*)color {
  if (_contents) {
    airc::PageChannel::GetOrCreate(_contents)->SetPageColor(
        color ? base::SysNSStringToUTF8(color) : std::string());
  }
}

- (void)setPageBackgroundColor:(NSColor*)color {
  _pageBackgroundColor = color;
  if (!_contents) {
    return;
  }
  if (!color) {
    airc::SetHostPageBaseBackgroundColor(_contents, std::nullopt);
    return;
  }
  NSColor* rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  airc::SetHostPageBaseBackgroundColor(
      _contents, SkColorSetARGB(rgb.alphaComponent * 255, rgb.redComponent * 255,
                                rgb.greenComponent * 255, rgb.blueComponent * 255));
}

- (NSColor*)contentsBackgroundColor {
  std::optional<SkColor> color =
      _contents ? airc::ContentsBackgroundColor(_contents) : std::nullopt;
  return color ? [NSColor colorWithSRGBRed:SkColorGetR(*color) / 255.0
                                     green:SkColorGetG(*color) / 255.0
                                      blue:SkColorGetB(*color) / 255.0
                                     alpha:1]
               : nil;
}

- (void)setContentsBackgroundColor:(NSColor*)color {
  if (!_contents) {
    return;
  }
  NSColor* rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  airc::SetContentsBackgroundColor(
      _contents, rgb ? std::optional<SkColor>(SkColorSetRGB(std::lround(rgb.redComponent * 255),
                                                            std::lround(rgb.greenComponent * 255),
                                                            std::lround(rgb.blueComponent * 255)))
                     : std::nullopt);
}

- (void)executeJavaScript:(NSString*)code frame:(NSString*)frameId {
  if (!_contents) {
    return;
  }
  airc::EndAheadBlank(_contents);
  airc::PageChannel* channel =
      airc::PageChannel::GetOrCreate(_contents);
  if (frameId) {
    channel->ExecuteInFrame(base::SysNSStringToUTF8(frameId),
                            base::SysNSStringToUTF8(code));
  } else {
    channel->Execute(base::SysNSStringToUTF8(code));
  }
}

- (void)evaluate:(NSString*)code completion:(void (^)(NSString*))completion {
  if (!_contents) {
    completion(nil);
    return;
  }
  airc::EndAheadBlank(_contents);
  airc::PageChannel::GetOrCreate(_contents)->Evaluate(
      base::SysNSStringToUTF8(code),
      base::BindOnce(
          [](void (^completion)(NSString*), const std::optional<std::string>& json) {
            completion(json ? NS(*json) : nil);
          },
          completion));
}

- (BOOL)hasLiveFrame:(NSString*)frameId {
  return _contents && (!frameId.length ||
                       airc::PageChannel::GetOrCreate(_contents)->HasFrame(
                           base::SysNSStringToUTF8(frameId)));
}

- (void)callPage:(NSString*)kind json:(NSString*)json {
  if (_contents) {
    airc::EndAheadBlank(_contents);
    airc::PageChannel::GetOrCreate(_contents)->CallPage(
        base::SysNSStringToUTF8(kind), base::SysNSStringToUTF8(json));
  }
}

- (void)grantUserActivationToFrame:(NSString*)frameId {
  if (_contents) {
    airc::PageChannel::GetOrCreate(_contents)->GrantUserActivation(
        base::SysNSStringToUTF8(frameId));
  }
}

- (void)callFrame:(NSString*)frameId kind:(NSString*)kind json:(NSString*)json {
  if (_contents) {
    airc::EndAheadBlank(_contents);
    airc::PageChannel::GetOrCreate(_contents)->CallFrame(
        base::SysNSStringToUTF8(frameId), base::SysNSStringToUTF8(kind),
        base::SysNSStringToUTF8(json));
  }
}

@end

// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

// Copyright 2026 Ardia. Apache-2.0.

#include "airc/core/airc_picture_in_picture.h"
#include <cmath>
#include "base/strings/utf_string_conversions.h"
#include "airc/core/airc_pip_window_hooks.h"
#import <QuartzCore/QuartzCore.h>
#include "chrome/browser/ui/views/frame/browser_view.h"
#include "chrome/browser/ui/views/frame/picture_in_picture_browser_frame_view.h"
#include "chrome/common/chrome_isolated_world_ids.h"
#include "content/public/browser/render_frame_host.h"
#include "components/remote_cocoa/app_shim/native_widget_mac_nswindow.h"
#include "ui/views/widget/native_widget_mac.h"
#include "ui/views/view_utils.h"
#include "ui/views/window/non_client_view.h"
#include "ui/base/hit_test.h"
#include "chrome/common/pref_names.h"
#include "components/prefs/pref_service.h"
#include "components/prefs/scoped_user_pref_update.h"
#include "airc/core/airc_content_hooks.h"
#include "airc/core/airc_host_visibility.h"

#import <AppKit/AppKit.h>
#import <objc/runtime.h>

#include "base/functional/bind.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/scoped_observation.h"
#include "base/task/single_thread_task_runner.h"
#include "base/strings/stringprintf.h"
#include "base/strings/sys_string_conversions.h"
#include "base/time/time.h"
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "chrome/browser/media/webrtc/media_capture_devices_dispatcher.h"
#include "chrome/browser/media/webrtc/media_stream_capture_indicator.h"
#include "chrome/browser/picture_in_picture/auto_picture_in_picture_tab_helper.h"
#include "chrome/browser/picture_in_picture/picture_in_picture_window_manager.h"
#include "chrome/browser/profiles/profile.h"
#include "components/content_settings/core/browser/host_content_settings_map.h"
#include "chrome/browser/ui/browser_window/public/browser_collection_observer.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/views/overlay/video_overlay_window_views.h"
#include "content/public/browser/picture_in_picture_window_controller.h"
#include "content/public/browser/video_picture_in_picture_window_controller.h"
#include "content/public/browser/web_contents.h"
#include "ui/base/base_window.h"
#include "ui/gfx/native_ui_types.h"
#include "airc/core/airc_browser.h"
#include "airc/core/airc_launch_switches.h"
#import "airc/core/airc_internal.h"

// Window policy and pointer handling shared by video and Document PiP.
#include "airc/core/airc_pip_window.inc"

namespace airc {

namespace {
bool AutoPipAllowed(content::WebContents* contents);
void PlacePipWindow();
void InstallAppOverlay();
void SavePipFrame(NSNotification* note);

void Report(base::WeakPtr<content::WebContents> contents, bool active, NSString* kind) {
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(
                     [](base::WeakPtr<content::WebContents> contents, bool active,
                        NSString* kind) {
                       if (!contents) {
                         return;
                       }
                       AircTab* tab = TabBridge::GetOrCreate(contents.get())->tab();
                       id<AircTabDelegate> delegate = tab.delegate;
                       if ([delegate respondsToSelector:@selector
                                     (tab:didChangePictureInPicture:)]) {
                         [delegate tab:tab
                             didChangePictureInPicture:@{
                               @"active" : @(active),
                               @"kind" : kind,
                             }];
                       }
                     },
                     contents, active, kind));
}

bool Background() {
  return BackgroundInstance();
}

}
}

@interface AircInvisibleWindowPin : NSObject
@end

@implementation AircInvisibleWindowPin

- (void)observeValueForKeyPath:(NSString*)keyPath
                      ofObject:(id)object
                        change:(NSDictionary*)change
                       context:(void*)context {
  NSWindow* window = object;
  if (window.alphaValue != 0) {
    window.alphaValue = 0;
  }
}

@end

namespace airc {
namespace {

const void* const kInvisiblePinKey = &kInvisiblePinKey;

void MakeInvisible(NSWindow* window) {
  window.alphaValue = 0;
  window.ignoresMouseEvents = YES;
  if (!objc_getAssociatedObject(window, kInvisiblePinKey)) {
    AircInvisibleWindowPin* pin = [[AircInvisibleWindowPin alloc] init];
    objc_setAssociatedObject(window, kInvisiblePinKey, pin, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [window addObserver:pin forKeyPath:@"alphaValue" options:0 context:nullptr];
  }
}

void HideVideoOverlay(content::WebContents* opener) {
  auto* overlay = static_cast<VideoOverlayWindowViews*>(
      content::PictureInPictureWindowController::GetOrCreateVideoPictureInPictureController(
          opener)
          ->GetWindowForTesting());
  if (overlay) {
    MakeInvisible(overlay->GetNativeWindow().GetNativeNSWindow());
  }
}

class DocumentPipBrowsers : public BrowserCollectionObserver {
 public:
  DocumentPipBrowsers() { observation_.Observe(GlobalBrowserCollection::GetInstance()); }

  void OnBrowserCreated(BrowserWindowInterface* browser) override {
    if (browser->GetType() != BrowserWindowInterface::TYPE_PICTURE_IN_PICTURE ||
        WindowHost::ForBrowser(browser) || !browser->GetWindow()) {
      return;
    }
    MakeInvisible(browser->GetWindow()->GetNativeWindow().GetNativeNSWindow());
  }

 private:
  base::ScopedObservation<GlobalBrowserCollection, BrowserCollectionObserver> observation_{
      this};
};

class PictureInPictureObserver : public PictureInPictureWindowManager::Observer {
 public:
  void OnEnterPictureInPicture() override {
    PictureInPictureWindowManager* manager = PictureInPictureWindowManager::GetInstance();
    content::WebContents* opener = manager->GetWebContents();
    if (opener_ && opener_.get() != opener) {
      Report(opener_, false, kind_);
    }
    opener_ = opener ? opener->GetWeakPtr() : nullptr;
    if (Background() && opener && !manager->GetChildWebContents()) {
      HideVideoOverlay(opener);
    }
    if (!opener) {
      return;
    }
    kind_ = manager->GetChildWebContents() ? @"document" : @"video";
    if (PictureInPictureTracing()) {
      auto* helper = AutoPictureInPictureTabHelper::FromWebContents(opener);
      TracePictureInPicture(base::StringPrintf(
          "engine: PiP window opened (%s) for %s; Chrome's auto PiP: %d",
          kind_.UTF8String, std::string(opener->GetLastCommittedURL().host()).c_str(),
          helper && helper->IsInAutoPictureInPicture()));
    }
    // A video window is shown in this task, before its first frame: the app's
    // controls replace Chromium's now. Document PiP may finish later (placement).
    InstallAppOverlay();
    // Window creation/show finishes after the manager's notification.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce(&PlacePipWindow));
    Report(opener_, true, kind_);
  }

  void OnExitPictureInPicture() override {
    if (PictureInPictureTracing()) {
      NSArray<NSString*>* stack = NSThread.callStackSymbols;
      NSMutableString* frames = [NSMutableString string];
      for (NSUInteger i = 1; i < MIN(stack.count, (NSUInteger)14); i++) {
        NSString* frame = stack[i];
        NSRange at = [frame rangeOfString:@"0x"];
        [frames appendFormat:@"\n    %@", at.location == NSNotFound ? frame : [frame substringFromIndex:at.location]];
      }
      TracePictureInPicture("engine: PiP window closed, by" + base::SysNSStringToUTF8(frames));
    }
    if (!opener_) {
      return;
    }
    Report(opener_, false, kind_);
    opener_ = nullptr;
  }

 private:
  base::WeakPtr<content::WebContents> opener_;
  NSString* __strong kind_ = @"video";
};

}

bool PictureInPictureTracing() {
  static const bool tracing = Traced("pip");
  return tracing;
}

void TracePictureInPicture(const std::string& line) {
  if (!PictureInPictureTracing()) {
    return;
  }
  NSString* text = [NSString stringWithFormat:@"%.3f %s\n", NSDate.date.timeIntervalSince1970,
                                               line.c_str()];
  // The host owns stderr capture. Do not write a shared, cross-profile /tmp log.
  fprintf(stderr, "%s", text.UTF8String);
}

namespace {

std::string AutoPictureInPictureInputs(content::WebContents* contents) {
  auto* helper = AutoPictureInPictureTabHelper::FromWebContents(contents);
  const GURL& url = contents->GetLastCommittedURL();
  Profile* profile = Profile::FromBrowserContext(contents->GetBrowserContext());
  const ContentSetting setting =
      HostContentSettingsMapFactory::GetForProfile(profile)->GetContentSetting(
          url, url, ContentSettingsType::AUTO_PICTURE_IN_PICTURE);
  scoped_refptr<MediaStreamCaptureIndicator> indicator =
      MediaCaptureDevicesDispatcher::GetInstance()->GetMediaStreamCaptureIndicator();
  return base::StringPrintf(
      "host=%s scheme=%s setting=%d registered=%d camera=%d mic=%d userMedia=%d audible=%d "
      "inAutoPiP=%d chromeEntered=%d pipWindowOpen=%d incognito=%d",
      std::string(url.host()).c_str(), std::string(url.scheme()).c_str(), setting,
      helper && helper->HasAutoPictureInPictureBeenRegistered(),
      indicator->IsCapturingVideo(contents), indicator->IsCapturingAudio(contents),
      indicator->IsCapturingUserMedia(contents), contents->IsCurrentlyAudible(),
      helper && helper->IsInAutoPictureInPicture(),
      helper && helper->AreAutoPictureInPicturePreconditionsMet(),
      PictureInPictureWindowManager::GetInstance()->GetWebContents() != nullptr,
      profile->IsOffTheRecord());
}

}

void TraceAutoPictureInPictureInputs(content::WebContents* contents, const char* when) {
  if (PictureInPictureTracing()) {
    TracePictureInPicture(std::string("engine: ") + when + ": " +
                          AutoPictureInPictureInputs(contents));
  }
}

void StartPictureInPictureObserver() {
  StartPipWindowPolicy();
  g_airc_auto_pip_allowed = &AutoPipAllowed;
  for (NSNotificationName name in @[NSWindowDidMoveNotification, NSWindowDidResizeNotification])
    [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil
        usingBlock:^(NSNotification* note) { SavePipFrame(note); }];
  static base::NoDestructor<PictureInPictureObserver> observer;
  PictureInPictureWindowManager::GetInstance()->AddObserver(observer.get());
  if (Background()) {
    static base::NoDestructor<DocumentPipBrowsers> documents;
  }
}

}

namespace airc {
namespace {
const char kPlacedPip = 0;
NSRect SavedFrame(Profile* profile, bool document = false) {
  const std::string* frame = profile->GetPrefs()->GetDict(prefs::kAppWindowPlacement)
      .FindString(document ? "airc_document_pip_frame" : "airc_pip_frame");
  return frame ? NSRectFromString(base::SysUTF8ToNSString(*frame)) : NSZeroRect;
}
void SaveFrame(Profile* profile, NSRect frame, bool document = false) {
  const char* key = document ? "airc_document_pip_frame" : "airc_pip_frame";
  ScopedDictPrefUpdate update(profile->GetPrefs(), prefs::kAppWindowPlacement);
  if (NSIsEmptyRect(frame)) update->Remove(key);
  else update->Set(key, base::SysNSStringToUTF8(NSStringFromRect(frame)));
}
NSWindow* PipWindow() {
  auto* manager = PictureInPictureWindowManager::GetInstance();
  if (auto* child = manager->GetChildWebContents())
    return child->GetTopLevelNativeWindow().GetNativeNSWindow();
  auto* opener = manager->GetWebContents();
  if (!opener) return nil;
  auto* overlay = static_cast<VideoOverlayWindowViews*>(
      content::PictureInPictureWindowController::GetOrCreateVideoPictureInPictureController(opener)->GetWindowForTesting());
  return overlay ? overlay->GetNativeWindow().GetNativeNSWindow() : nil;
}
// App overlay (engine/PIP.md "App overlay"): one hosted view per PiP window.
NSView* _Nullable (^__strong g_overlay_provider)(AircTab*, NSDictionary*) = nil;
VideoOverlayWindowViews* VideoOverlay(content::WebContents* opener) {
  return static_cast<VideoOverlayWindowViews*>(
      content::PictureInPictureWindowController::GetOrCreateVideoPictureInPictureController(opener)->GetWindowForTesting());
}
int DocumentTopBarHeight(NSWindow* window) {
  auto* widget = views::Widget::GetWidgetForNativeWindow(gfx::NativeWindow(window));
  auto* frame = widget && widget->non_client_view()
      ? views::AsViewClass<PictureInPictureBrowserFrameView>(widget->non_client_view()->frame_view()) : nullptr;
  return frame ? frame->GetTopAreaHeight() : 34;
}
void InstallAppOverlay() {
  auto* manager = PictureInPictureWindowManager::GetInstance();
  content::WebContents* opener = manager->GetWebContents();
  NSWindow* window = PipWindow();
  if (!opener || !window || !window.contentView || !g_overlay_provider || Background() ||
      !SwitchOn("pipAppControls")) return;
  if (NSView* existing = objc_getAssociatedObject(window, &kPipOverlay)) {
    // Web content attached after the overlay must not cover it.
    if (existing.superview == window.contentView && window.contentView.subviews.lastObject != existing)
      [window.contentView addSubview:existing positioned:NSWindowAbove relativeTo:nil];
    return;
  }
  bool document = manager->GetChildWebContents() != nullptr;
  VideoOverlayWindowViews* video = document ? nullptr : VideoOverlay(opener);
  // Chromium's own auto-PiP permission prompt keeps Chromium's UI.
  if (!document && (!video || video->get_overlay_view_for_testing())) return;
  NSMutableDictionary* info = [NSMutableDictionary dictionaryWithDictionary:@{
      @"kind": document ? @"document" : @"video", @"window": window}];
  if (document) info[@"topBarHeight"] = @(DocumentTopBarHeight(window));
  NSView* view = g_overlay_provider(TabBridge::GetOrCreate(opener)->tab(), info);
  if (!view) return;
  objc_setAssociatedObject(window, &kPipOverlay, view, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  // Public Views API (used by Chromium's own tests): controls, title and scrims
  // stay hidden and out of hit testing; the frame keeps drag and resize.
  if (video) video->ForceControlsVisibleForTesting(false, false);
  view.frame = window.contentView.bounds;
  view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [window.contentView addSubview:view positioned:NSWindowAbove relativeTo:nil];
  TracePictureInPicture(std::string("engine: app overlay installed (") + (document ? "document" : "video") + ")");
}
bool AutoPipAllowed(content::WebContents* contents) {
  if (g_airc_auto_picture_in_picture_off || !SwitchOn("autoPip")) return false;
  auto* profile = Profile::FromBrowserContext(contents->GetBrowserContext());
  auto* settings = HostContentSettingsMapFactory::GetForProfile(profile);
  return settings->GetDefaultContentSetting(ContentSettingsType::AUTO_PICTURE_IN_PICTURE,
                                            nullptr) != CONTENT_SETTING_BLOCK;
}
// The video's own shape (its natural size), else the window's as Chromium fitted it; 0 for Document PiP, whose page
// picks its size.
double PipAspect(content::WebContents* opener, NSWindow* window) {
  if (PictureInPictureWindowManager::GetInstance()->GetChildWebContents()) return 0;
  if (auto* video = VideoOverlay(opener); video && !video->GetNaturalSize().IsEmpty())
    return static_cast<double>(video->GetNaturalSize().width()) / video->GetNaturalSize().height();
  return window.frame.size.height > 0 ? window.frame.size.width / window.frame.size.height : 0;
}
// The remembered placement is a corner position and a size (its area), never a shape: each video keeps its own
// aspect ratio, as macOS's picture in picture does, and the window fits the screen's visible frame.
void PlacePipWindow() {
  InstallAppOverlay();
  auto* opener = PictureInPictureWindowManager::GetInstance()->GetWebContents();
  NSWindow* window = PipWindow();
  if (!opener || !window || !SwitchOn("pipPlacement")) return;
  auto* profile = Profile::FromBrowserContext(opener->GetBrowserContext());
  const bool document = PictureInPictureWindowManager::GetInstance()->GetChildWebContents() != nullptr;
  NSRect saved = SavedFrame(profile, document);
  NSScreen* screen = opener->GetTopLevelNativeWindow().GetNativeNSWindow().screen ?: NSScreen.mainScreen;
  for (NSScreen* candidate in NSScreen.screens)
    if (!NSIsEmptyRect(NSIntersectionRect(candidate.visibleFrame, saved))) { screen = candidate; break; }
  NSRect area = NSInsetRect(screen.visibleFrame, 20, 20);
  NSRect frame = window.frame;
  double aspect = PipAspect(opener, window);
  if (!NSIsEmptyRect(saved) && aspect > 0) {
    double size = saved.size.width * saved.size.height;
    frame.size = NSMakeSize(std::sqrt(size * aspect), std::sqrt(size / aspect));
  }
  // Document PiP already has Chromium's requested/cached viewport and min/max
  // constraints. Only video gets our additional proportional screen fit.
  if (!document) {
    double fit = MIN(1.0, MIN(area.size.width / frame.size.width, area.size.height / frame.size.height));
    frame.size = NSMakeSize(std::floor(frame.size.width * fit), std::floor(frame.size.height * fit));
  }
  if (NSIsEmptyRect(saved)) {
    frame.origin = NSMakePoint(NSMaxX(area)-frame.size.width, NSMinY(area));
  } else {
    // The saved window's corner nearest the screen's stays where it was.
    bool right = NSMidX(saved) > NSMidX(area), top = NSMidY(saved) > NSMidY(area);
    frame.origin = NSMakePoint(right ? NSMaxX(saved)-frame.size.width : NSMinX(saved),
                               top ? NSMaxY(saved)-frame.size.height : NSMinY(saved));
  }
  frame.origin.x = MAX(NSMinX(area), MIN(frame.origin.x, NSMaxX(area)-frame.size.width));
  frame.origin.y = MAX(NSMinY(area), MIN(frame.origin.y, NSMaxY(area)-frame.size.height));
  ConfigurePipWindow(window, document);
  [window setFrame:frame display:YES];
  objc_setAssociatedObject(window, &kPlacedPip, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  // Notifications are process-scoped; only the current PiP is persisted.
}
void SavePipFrame(NSNotification* note) {
  NSWindow* window = PipWindow();
  auto* opener = PictureInPictureWindowManager::GetInstance()->GetWebContents();
  if (!window || !objc_getAssociatedObject(window, &kPlacedPip) || note.object != window || !opener ||
      !SwitchOn("pipPlacement")) return;
  // A frame that isn't the video's shape (the app's collapsed pill, a step of its animation) is never remembered.
  double aspect = PipAspect(opener, window), now = window.frame.size.width / MAX(1.0, window.frame.size.height);
  if (aspect > 0 && std::abs(now / aspect - 1) > 0.02) return;
  SaveFrame(Profile::FromBrowserContext(opener->GetBrowserContext()), window.frame,
            PictureInPictureWindowManager::GetInstance()->GetChildWebContents() != nullptr);
}
}  // namespace
}  // namespace airc

@implementation AircProfile (PictureInPicture)
- (BOOL)autoPictureInPictureEnabled {
  if (self.destroyed || !self.chromeProfile) return NO;
  return HostContentSettingsMapFactory::GetForProfile(self.chromeProfile)->GetDefaultContentSetting(
      ContentSettingsType::AUTO_PICTURE_IN_PICTURE, nullptr) != CONTENT_SETTING_BLOCK;
}
- (void)setAutoPictureInPictureEnabled:(BOOL)enabled {
  NSParameterAssert(NSThread.isMainThread);
  if (self.destroyed || !self.chromeProfile) return;
  HostContentSettingsMapFactory::GetForProfile(self.chromeProfile)->SetDefaultContentSetting(
      ContentSettingsType::AUTO_PICTURE_IN_PICTURE, enabled ? CONTENT_SETTING_ALLOW : CONTENT_SETTING_BLOCK);
  auto* opener = PictureInPictureWindowManager::GetInstance()->GetWebContents();
  auto* helper = opener ? AutoPictureInPictureTabHelper::FromWebContents(opener) : nullptr;
  if (!enabled && opener && opener->GetBrowserContext() == self.chromeProfile && helper && helper->IsInAutoPictureInPicture())
    PictureInPictureWindowManager::GetInstance()->ExitPictureInPicture();
}
- (BOOL)setAutoPictureInPictureException:(NSString*)origin enabled:(NSNumber*)enabled {
  NSParameterAssert(NSThread.isMainThread);
  if (self.destroyed || !self.chromeProfile) return NO;
  GURL url(base::SysNSStringToUTF8(origin));
  if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS() || url.has_username() || url.has_password()) return NO;
  url = url.DeprecatedGetOriginAsURL();
  HostContentSettingsMapFactory::GetForProfile(self.chromeProfile)->SetContentSettingDefaultScope(
      url, url, ContentSettingsType::AUTO_PICTURE_IN_PICTURE,
      !enabled ? CONTENT_SETTING_DEFAULT : enabled.boolValue ? CONTENT_SETTING_ALLOW : CONTENT_SETTING_BLOCK);
  auto* opener = PictureInPictureWindowManager::GetInstance()->GetWebContents();
  auto* helper = opener ? AutoPictureInPictureTabHelper::FromWebContents(opener) : nullptr;
  if (enabled && !enabled.boolValue && opener && opener->GetBrowserContext() == self.chromeProfile &&
      opener->GetLastCommittedURL().DeprecatedGetOriginAsURL() == url && helper && helper->IsInAutoPictureInPicture())
    PictureInPictureWindowManager::GetInstance()->ExitPictureInPicture();
  return YES;
}
- (NSRect)pictureInPictureFrame {
  if (self.destroyed || !self.chromeProfile) return NSZeroRect;
  return airc::SavedFrame(self.chromeProfile);
}
- (void)setPictureInPictureFrame:(NSRect)frame {
  NSParameterAssert(NSThread.isMainThread);
  if (self.destroyed || !self.chromeProfile || !std::isfinite(frame.origin.x) ||
      !std::isfinite(frame.origin.y) || !std::isfinite(frame.size.width) || !std::isfinite(frame.size.height)) return;
  airc::SaveFrame(self.chromeProfile, frame);
  if (NSIsEmptyRect(frame)) airc::SaveFrame(self.chromeProfile, frame, true);
  auto* opener = PictureInPictureWindowManager::GetInstance()->GetWebContents();
  if (opener && opener->GetBrowserContext() == self.chromeProfile) airc::PlacePipWindow();
}
@end

@implementation AircTab (PictureInPicture)
- (void)setPictureInPictureWindowActive:(BOOL)active {
  NSParameterAssert(NSThread.isMainThread);
  airc::SetPictureInPictureWindowActive(self.contents, active);
}
- (NSDictionary<NSString*, id>*)pictureInPictureState {
  auto* manager = PictureInPictureWindowManager::GetInstance();
  NSWindow* window = airc::PipWindow();
  if (!self.contents || manager->GetWebContents() != self.contents || !window) return nil;
  bool document = manager->GetChildWebContents() != nullptr;
  auto* video = document ? nullptr : airc::VideoOverlay(self.contents);
  NSView* document_view = document ? manager->GetChildWebContents()->GetNativeView().GetNativeNSView() : nil;
  return @{@"kind": document ? @"document" : @"video", @"window": window,
           @"appOverlay": objc_getAssociatedObject(window, &airc::kPipOverlay) ?: NSNull.null,
           @"documentView": document_view ?: NSNull.null,
           @"topBarHeight": @(document ? airc::DocumentTopBarHeight(window) : 0),
           @"chromeControls": @(video && (video->AreControlsVisible() || video->AreTitleAndScrimVisibleForTesting()))};
}
@end

@implementation AircEngine (PictureInPictureOverlay)
+ (void)setPictureInPictureOverlayProvider:(NSView* _Nullable (^)(AircTab*, NSDictionary*))provider {
  NSParameterAssert(NSThread.isMainThread);
  airc::g_overlay_provider = [provider copy];
}
@end

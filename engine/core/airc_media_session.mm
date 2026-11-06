// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#import "airc/core/airc_internal.h"
#include "airc/core/airc_media_session.h"
#include <cmath>
#include <algorithm>
#include <set>
#include "base/no_destructor.h"
#include "base/strings/sys_string_conversions.h"
#include "base/supports_user_data.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/media/webrtc/media_capture_devices_dispatcher.h"
#include "chrome/browser/media/webrtc/media_stream_capture_indicator.h"
#include "content/public/browser/media_session.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "mojo/public/cpp/bindings/receiver.h"
#include "services/media_session/public/cpp/media_metadata.h"
#include "services/media_session/public/cpp/media_position.h"
namespace {
using Action = media_session::mojom::MediaSessionAction;
using Info = media_session::mojom::MediaSessionInfo;
using ImageType = media_session::mojom::MediaSessionImageType;
const struct { NSString* name; Action action; } kActions[] = {
  {@"play", Action::kPlay}, {@"pause", Action::kPause}, {@"stop", Action::kStop},
  {@"previoustrack", Action::kPreviousTrack}, {@"nexttrack", Action::kNextTrack},
  {@"seekbackward", Action::kSeekBackward}, {@"seekforward", Action::kSeekForward},
  {@"seekto", Action::kSeekTo}, {@"togglemicrophone", Action::kToggleMicrophone},
  {@"togglecamera", Action::kToggleCamera}, {@"hangup", Action::kHangUp},
  {@"enterpictureinpicture", Action::kEnterPictureInPicture}};
class Media;
auto& Sessions() { static base::NoDestructor<std::set<Media*>> s; return *s; }
class ProfileMedia : public base::SupportsUserData::Data {
 public:
  void (^handler)(NSArray*);
  static ProfileMedia* Get(AircProfile* p) {
    if (!p.chromeProfile || airc::IsProfileDying(p.chromeProfile)) return nullptr;
    static int key;
    auto* data = static_cast<ProfileMedia*>(p.chromeProfile->GetUserData(&key));
    if (!data) {
      auto owned = std::make_unique<ProfileMedia>(); data = owned.get();
      p.chromeProfile->SetUserData(&key, std::move(owned));
    }
    return data;
  }
};
void NotifyProfile(AircProfile* profile) {
  if (auto* state = ProfileMedia::Get(profile); state && state->handler)
    state->handler(profile.mediaTabs);
}
class Media : public base::SupportsUserData::Data,
              public content::WebContentsObserver,
              public media_session::mojom::MediaSessionObserver,
              public MediaStreamCaptureIndicator::Observer {
 public:
  explicit Media(AircTab* tab) : content::WebContentsObserver(tab.contents), tab_(tab), profile_(tab.profile) {
    Sessions().insert(this);
    indicator_ = MediaCaptureDevicesDispatcher::GetInstance()->GetMediaStreamCaptureIndicator();
    indicator_->AddObserver(this);
    content::MediaSession::Get(tab.contents)->AddObserver(receiver_.BindNewPipeAndPassRemote());
  }
  ~Media() override { indicator_->RemoveObserver(this); Sessions().erase(this); }
  void WebContentsDestroyed() override {
    AircProfile* profile = profile_;
    Sessions().erase(this);
    handler_ = nil;
    NotifyProfile(profile);
  }
  static Media* Get(AircTab* tab) {
    auto* c = tab.contents;
    if (!c) return nullptr;
    static int key;
    auto* data = static_cast<Media*>(c->GetUserData(&key));
    if (!data) {
      auto owned = std::make_unique<Media>(tab); data = owned.get();
      c->SetUserData(&key, std::move(owned));
    }
    return data;
  }
  NSDictionary* Snapshot() {
    auto* c = web_contents();
    if (!c) return @{};
    auto* session = content::MediaSession::Get(c);
    auto info = session->GetMediaSessionInfoSync();
    const auto& meta = session->GetMediaSessionMetadata();
    auto pos = session->GetMediaSessionPosition();
    NSMutableArray* actions = [NSMutableArray array];
    auto supported = session->GetMediaSessionActionsSync();
    for (const auto& a : kActions)
      if (std::ranges::find(supported, a.action) != supported.end()) [actions addObject:a.name];
    bool active = info->state != Info::SessionState::kInactive;
    return @{@"active": @(active), @"playbackState": !active ? @"none" :
      info->playback_state == media_session::mojom::MediaPlaybackState::kPlaying ? @"playing" : @"paused",
      @"title": base::SysUTF16ToNSString(meta.title), @"artist": base::SysUTF16ToNSString(meta.artist),
      @"album": base::SysUTF16ToNSString(meta.album), @"artwork": artwork_ ?: @[],
      @"duration": @(pos ? pos->duration().InSecondsF() : -1),
      @"position": @(pos ? pos->GetPosition().InSecondsF() : -1),
      @"playbackRate": @(pos ? pos->playback_rate() : 0), @"actions": actions,
      @"microphoneActive": info->microphone_state == media_session::mojom::MicrophoneState::kUnknown ? (id)NSNull.null : @(info->microphone_state == media_session::mojom::MicrophoneState::kUnmuted),
      @"cameraActive": info->camera_state == media_session::mojom::CameraState::kUnknown ? (id)NSNull.null : @(info->camera_state == media_session::mojom::CameraState::kTurnedOn),
      @"capture": @{@"microphone": @(indicator_->IsCapturingAudio(c)), @"camera": @(indicator_->IsCapturingVideo(c)),
        @"screen": @(indicator_->IsCapturingDisplay(c) || indicator_->IsCapturingWindow(c)),
        @"tab": @(indicator_->IsCapturingTab(c))}};
  }
  void Changed() {
    if (handler_) handler_(Snapshot());
    NotifyProfile(profile_);
  }
  void MediaSessionInfoChanged(media_session::mojom::MediaSessionInfoPtr) override { Changed(); }
  void MediaSessionMetadataChanged(const std::optional<media_session::MediaMetadata>&) override { Changed(); }
  void MediaSessionActionsChanged(const std::vector<Action>&) override { Changed(); }
  void MediaSessionPositionChanged(const std::optional<media_session::MediaPosition>&) override { Changed(); }
  void MediaSessionImagesChanged(const base::flat_map<ImageType, std::vector<media_session::MediaImage>>& images) override {
    NSMutableArray* urls = [NSMutableArray array];
    auto it = images.find(ImageType::kArtwork);
    if (it != images.end()) for (const auto& image : it->second) [urls addObject:base::SysUTF8ToNSString(image.src.spec())];
    artwork_ = urls; Changed();
  }
#define CAPTURE_CHANGED(Name) void Name(content::WebContents* c, bool) override { if (c == web_contents()) Changed(); }
  CAPTURE_CHANGED(OnIsCapturingVideoChanged)
  CAPTURE_CHANGED(OnIsCapturingAudioChanged)
  CAPTURE_CHANGED(OnIsCapturingTabChanged)
  CAPTURE_CHANGED(OnIsCapturingWindowChanged)
  CAPTURE_CHANGED(OnIsCapturingDisplayChanged)
#undef CAPTURE_CHANGED
  __weak AircTab* tab_;
  __weak AircProfile* profile_;
  void (^handler_)(NSDictionary*);
  NSArray* __strong artwork_;
  scoped_refptr<MediaStreamCaptureIndicator> indicator_;
  mojo::Receiver<media_session::mojom::MediaSessionObserver> receiver_{this};
};
}
namespace airc { void TrackMediaSession(AircTab* tab) { Media::Get(tab); } }
@implementation AircTab (MediaSession)
- (NSDictionary*)mediaSession { auto* m = Media::Get(self); return m ? m->Snapshot() : @{}; }
- (void)observeMediaSession:(void (^)(NSDictionary*))handler {
  if (auto* m = Media::Get(self)) { m->handler_ = [handler copy]; if (handler) handler(m->Snapshot()); }
}
- (BOOL)performMediaAction:(NSString*)action value:(double)value {
  if (!self.contents || !std::isfinite(value)) return NO;
  auto* session = content::MediaSession::Get(self.contents);
  auto actions = session->GetMediaSessionActionsSync();
  for (const auto& a : kActions) {
    if (![action isEqual:a.name]) continue;
    if (std::ranges::find(actions, a.action) == actions.end()) return NO;
    if (a.action == Action::kSeekTo) { if (value < 0) return NO; session->SeekTo(base::Seconds(value)); }
    else if (a.action == Action::kSeekBackward || a.action == Action::kSeekForward) {
      if (value <= 0) return NO;
      session->Seek(base::Seconds(a.action == Action::kSeekBackward ? -value : value));
    } else if (a.action == Action::kPlay) session->Resume(content::MediaSession::SuspendType::kUI);
    else if (a.action == Action::kPause) session->Suspend(content::MediaSession::SuspendType::kUI);
    else if (a.action == Action::kStop) session->Stop(content::MediaSession::SuspendType::kUI);
    else if (a.action == Action::kPreviousTrack) session->PreviousTrack();
    else if (a.action == Action::kNextTrack) session->NextTrack();
    else if (a.action == Action::kEnterPictureInPicture) session->EnterPictureInPicture();
    else session->DidReceiveAction(a.action);
    return YES;
  }
  return NO;
}
@end
@interface AircProfile (MediaLibrary)
@end
@implementation AircProfile (MediaLibrary)
- (NSArray<AircTab*>*)mediaTabs {
  NSMutableArray* tabs = [NSMutableArray array];
  for (auto* m : Sessions()) {
    AircTab* tab = m->tab_;
    if (!tab || tab.closed || tab.profile != self) continue;
    NSDictionary* snapshot = m->Snapshot();
    bool capture = false;
    for (NSNumber* value in [snapshot[@"capture"] allValues]) capture |= value.boolValue;
    if ([snapshot[@"active"] boolValue] || capture) [tabs addObject:tab];
  }
  return tabs;
}
- (void)observeMediaTabs:(void (^)(NSArray<AircTab*>*))handler {
  if (auto* state = ProfileMedia::Get(self)) { state->handler = [handler copy]; if (handler) handler(self.mediaTabs); }
}
@end

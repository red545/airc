#include "airc/core/airc_passkeys.h"
#include "airc/core/airc_memory.h"
#include "airc/core/airc_drm_policy.h"
#include "chrome/common/pref_names.h"
#include "chrome/browser/download/download_prefs.h"
// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#import "airc/core/public/Airc.h"

#include <memory>
#include <set>
#include <stdio.h>
#include "chrome/browser/profiles/profile_attributes_storage.h"
#include <sstream>
#include <string>
#include <vector>

#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/no_destructor.h"
#include "base/scoped_observation.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/thread_pool.h"
#include "base/time/time.h"
#include "chrome/browser/apps/platform_apps/shortcut_manager.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "chrome/browser/lifetime/browser_shutdown.h"
#include "chrome/browser/profiles/delete_profile_helper.h"
#include "chrome/browser/profiles/nuke_profile_directory_utils.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_destroyer.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/profiles/profile_manager_observer.h"
#include "chrome/browser/profiles/profile_metrics.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/browser_window.h"
#include "chrome/browser/ui/browser_window/public/desktop_browser_window_capabilities.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "components/content_settings/core/browser/host_content_settings_map.h"
#include "components/keep_alive_registry/keep_alive_registry.h"
#include "components/prefs/pref_service.h"
#include "components/version_info/version_info.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/browser_child_process_observer.h"
#include "content/public/browser/child_process_data.h"
#include "content/public/browser/child_process_termination_info.h"
#include "content/public/common/process_type.h"
#include "airc/core/airc_browser.h"
#include "airc/core/airc_browser_window.h"
#include "airc/core/airc_cast_dialog.h"
#include "airc/core/airc_content_hooks.h"
#include "airc/core/airc_desktop_capture.h"
#include "airc/core/airc_device_chooser.h"
#include "airc/core/airc_extension_shortcuts.h"
#include "airc/core/airc_extension_view.h"
#include "airc/core/airc_external_apps.h"
#include "airc/core/airc_hooks.h"
#include "airc/core/airc_host_visibility.h"
#include "airc/core/airc_modal_dialog_host.h"
#include "airc/core/airc_installed_bubble.h"
#include "airc/core/airc_lifetime.h"
#include "airc/core/airc_main_delegate.h"
#include "airc/core/airc_page_script.h"
#include "airc/core/airc_permissions.h"
#include "airc/core/airc_picture_in_picture.h"
#include "airc/core/airc_video_upscaling.h"
#import "airc/core/airc_api_internal.h"
#import "airc/core/airc_internal.h"

extern "C" int ChromeMain(int argc, const char** argv);

namespace airc {

id<AircEngineDelegate> __strong g_delegate;
AircEngine* __strong g_engine;

NSString* NS(const std::string& s) {
  return base::SysUTF8ToNSString(s);
}

NSString* NS(const std::u16string& s) {
  return base::SysUTF16ToNSString(s);
}

}

using airc::g_delegate;
using airc::g_engine;
using airc::NS;

namespace {

// Conservatively refuse cleanup of any profile observed in this process,
// including asynchronous creation and profiles pending destruction.
std::set<base::FilePath>& SessionProfiles() {
  static base::NoDestructor<std::set<base::FilePath>> paths;
  return *paths;
}

void ApplyAutoPictureInPicture(Profile* profile) {
  auto* settings = HostContentSettingsMapFactory::GetForProfile(profile);
  // Preserve the profile opt-out across restart; ASK is Chromium's initial default.
  if (settings->GetDefaultContentSetting(ContentSettingsType::AUTO_PICTURE_IN_PICTURE,
                                         nullptr) == CONTENT_SETTING_ASK)
    settings->SetDefaultContentSetting(ContentSettingsType::AUTO_PICTURE_IN_PICTURE,
                                       CONTENT_SETTING_ALLOW);
}

void PrepareProfilePrefs(Profile* profile) {
  if (!profile || profile->IsOffTheRecord()) {
    return;
  }
  PrefService* prefs = profile->GetPrefs();
  if (prefs->FindPreference("session.restore_on_startup")) {
    prefs->SetInteger("session.restore_on_startup", 5);
  }
  if (prefs->FindPreference("download_bubble.partial_view_enabled")) {
    prefs->SetBoolean("download_bubble.partial_view_enabled", false);
  }
  prefs->SetBoolean(prefs::kEnableEncryptedMedia, airc::ProtectedContentEnabled());
  ApplyAutoPictureInPicture(profile);
}

class ProfilePrefsApplier : public ProfileManagerObserver {
 public:
  explicit ProfilePrefsApplier(ProfileManager* manager) {
    observation_.Observe(manager);
    for (auto* profile : manager->GetLoadedProfiles()) SessionProfiles().insert(profile->GetPath());
  }
  void OnProfileCreationStarted(Profile* profile) override { SessionProfiles().insert(profile->GetPath()); }
  void OnProfileAdded(Profile* profile) override {
    SessionProfiles().insert(profile->GetPath());
    PrepareProfilePrefs(profile);
  }
  void OnProfileManagerDestroying() override { observation_.Reset(); }

 private:
  base::ScopedObservation<ProfileManager, ProfileManagerObserver> observation_{this};
};

// GPU uses BrowserChildProcessHostImpl too. Do not forward display names or
// arbitrary metrics names: some child process names can contain browsing data.
class ChildProcessObserver : public content::BrowserChildProcessObserver {
 public:
  ChildProcessObserver() { Add(this); }
  ~ChildProcessObserver() override { Remove(this); }
  void BrowserChildProcessCrashed(const content::ChildProcessData& data,
      const content::ChildProcessTerminationInfo& info) override { Report(data, info); }
  void BrowserChildProcessKilled(const content::ChildProcessData& data,
      const content::ChildProcessTerminationInfo& info) override { Report(data, info); }
  void BrowserChildProcessHostDisconnected(const content::ChildProcessData&) override {
    // Also emitted for normal teardown, after the classified notification.
    // No termination info here: reporting would invent crashes or double count.
  }
 private:
  void Report(const content::ChildProcessData& data,
              const content::ChildProcessTerminationInfo& info) {
    if (browser_shutdown::IsTryingToQuit() ||
        info.status == base::TERMINATION_STATUS_NORMAL_TERMINATION ||
        ![g_delegate respondsToSelector:@selector(engine:childProcessGone:status:exitCode:)])
      return;
    NSString* type = @"other";
    if (data.process_type == content::PROCESS_TYPE_GPU) type = @"gpu";
    if (data.process_type == content::PROCESS_TYPE_UTILITY) {
      const auto& name = data.metrics_name;
      if (name == "network.mojom.NetworkService") type = @"network";
      else if (name == "storage.mojom.StorageService") type = @"storage";
      else if (name == "audio.mojom.AudioService") type = @"audio";
      else if (name == "data_decoder.mojom.DataDecoderService") type = @"utility:data_decoder";
      else if (name == "video_capture.mojom.VideoCaptureService") type = @"utility:video_capture";
    }
    [g_delegate engine:g_engine childProcessGone:type
                 status:static_cast<int>(info.status) exitCode:info.exit_code];
  }
};
std::unique_ptr<ChildProcessObserver> child_process_observer;

void StartApplyingProfilePrefs() {
  ProfileManager* manager = g_browser_process->profile_manager();
  for (Profile* profile : manager->GetLoadedProfiles()) {
    PrepareProfilePrefs(profile);
  }
  static base::NoDestructor<ProfilePrefsApplier> applier(manager);
}


}

namespace airc {

void OnEngineStarted() {
  child_process_observer = std::make_unique<ChildProcessObserver>();
  StartApplyingProfilePrefs();
  InstallPermissionPrompts();
  StartMediaCaptureObserver();
  InstallExternalAppPrompts();
  StartPictureInPictureObserver();
  StartHostVisibility();
  InstallModalDialogHosting();
  StartMemoryPolicy();
  StartVideoUpscaling();
  [g_delegate engineDidStart];
}

void OnEngineShuttingDown() {
  child_process_observer.reset();
  StopMemoryPolicy();
  StopExtensionInstalledBubbles();
  CloseAllExtensionViews();
  [g_delegate engineWillShutDown];
}

}

extern "C" __attribute__((visibility("default"))) int AircMain(
    int argc,
    const char** argv) {
  return ChromeMain(argc, argv);
}

@implementation AircEngine

+ (int)runWithArgc:(int)argc
              argv:(const char**)argv
          delegate:(id<AircEngineDelegate>)delegate {
  bool is_browser = true;
  for (int i = 1; i < argc; ++i) {
    if (strncmp(argv[i], "--type=", 7) == 0) {
      is_browser = false;
    }
  }
  if (!is_browser) {
    return ChromeMain(argc, argv);
  }

  g_delegate = delegate;
  g_engine = [[AircEngine alloc] init];
  AppShortcutManager::SuppressShortcutsForTesting();

  int rv = ChromeMain(argc, argv);
  g_delegate = nil;
  return rv;
}

+ (AircEngine*)sharedEngine {
  return g_engine;
}

- (AircProfile*)defaultProfile {
  Profile* profile = ProfileManager::GetLastUsedProfileIfLoaded();
  return profile ? [AircProfile wrapperFor:profile] : nil;
}

- (void)loadProfile:(NSString*)directoryName
         completion:(void (^)(AircProfile*))completion {
  if (!directoryName.length || [directoryName hasPrefix:@"."] || [directoryName containsString:@"/"] ||
      [directoryName rangeOfString:[NSString stringWithFormat:@"%C", (unichar)0]].location != NSNotFound ||
      [directoryName isEqualToString:@"."] || [directoryName isEqualToString:@".."]) {
    completion(nil);
    return;
  }
  ProfileManager* manager = g_browser_process->profile_manager();
  base::FilePath path =
      manager->user_data_dir().Append(base::SysNSStringToUTF8(directoryName));
  Profile* loaded = manager->GetProfileByPath(path);
  if (IsProfileDirectoryMarkedForDeletion(path) ||
      (loaded && airc::IsProfileDeleting(loaded))) {
    completion(nil);
    return;
  }
  manager->CreateProfileAsync(
      path, base::BindOnce(
                [](void (^completion)(AircProfile*), Profile* profile) {
                  completion(profile && !airc::IsProfileDeleting(profile)
                                 ? [AircProfile wrapperFor:profile]
                                 : nil);
                },
                completion));
}

- (void)quit {
  airc::QuitEngine();
}

- (NSString*)pageScript {
  const std::string& script = airc::GetPageScript();
  return script.empty() ? nil : NS(script);
}

- (void)setPageScript:(NSString*)pageScript {
  airc::SetPageScript(pageScript ? base::SysNSStringToUTF8(pageScript)
                                   : std::string());
}

+ (void)resolvePermission:(NSString*)requestId
                   result:(NSString*)result
                 remember:(BOOL)remember {
  airc::ResolvePermission(base::SysNSStringToUTF8(requestId),
                            base::SysNSStringToUTF8(result), remember);
}

+ (void)startCasting:(int)dialogId sink:(NSString*)sinkId mode:(int)castMode {
  airc::StartCasting(dialogId, base::SysNSStringToUTF8(sinkId), castMode);
}

+ (void)stopCasting:(int)dialogId route:(NSString*)routeId {
  airc::StopCasting(dialogId, base::SysNSStringToUTF8(routeId));
}

+ (void)reservedShortcutsChanged {
  airc::ReservedShortcutsChanged();
}

+ (void)setVideoUpscaling:(BOOL)enabled {
  airc::SetVideoUpscalingEnabled(enabled);
}

+ (void)setVideoUpscalingTestConditions:(NSDictionary<NSString*, NSNumber*>*)conditions {
  NSNumber* low_power = conditions[@"lowPower"];
  NSNumber* thermal = conditions[@"thermalPressure"];
  airc::SetVideoUpscalingTestConditions(
      low_power ? std::optional<bool>(low_power.boolValue) : std::nullopt,
      thermal ? std::optional<bool>(thermal.boolValue) : std::nullopt);
}

+ (NSDictionary<NSString*, id>*)videoUpscalingState {
  return airc::VideoUpscalingState();
}

+ (void)setAutoPictureInPicture:(BOOL)enabled {
  g_airc_auto_picture_in_picture_off = !enabled;
  for (Profile* profile : g_browser_process->profile_manager()->GetLoadedProfiles()) {
    if (!profile->IsOffTheRecord()) {
      ApplyAutoPictureInPicture(profile);
    }
  }
}

+ (void)terminateCastRoute:(NSString*)routeId {
  airc::TerminateCastRoute(base::SysNSStringToUTF8(routeId));
}

+ (void)closeCastDialog:(int)dialogId {
  airc::CloseCastDialog(dialogId);
}

+ (void)selectDevice:(int)chooserId index:(int)index {
  airc::SelectDevice(chooserId, index);
}

+ (void)cancelDeviceChooser:(int)chooserId {
  airc::CancelDeviceChooser(chooserId);
}

+ (void)refreshDeviceChooser:(int)chooserId {
  airc::RefreshDeviceChooser(chooserId);
}

// The sender PID is supplied by the Apple Event Manager, not page content.
+ (NSString*)currentEventSourceBundleID {
  NSAppleEventDescriptor* event = NSAppleEventManager.sharedAppleEventManager.currentAppleEvent;
  NSAppleEventDescriptor* sender = [event attributeDescriptorForKeyword:'spid'];
  if (!sender) return nil;
  return [NSRunningApplication runningApplicationWithProcessIdentifier:sender.int32Value].bundleIdentifier;
}
- (BOOL)routeExternalURL:(NSString*)url {
  NSParameterAssert(NSThread.isMainThread);
  if (![g_delegate respondsToSelector:@selector(engine:routeLink:opener:)]) return NO;
  NSMutableDictionary* request = [@{@"url":url, @"source":@"external",
      @"disposition":@"foreground", @"userGesture":@YES} mutableCopy];
  NSString* sender = AircEngine.currentEventSourceBundleID;
  if (sender) request[@"sourceBundleID"] = sender;
  return [g_delegate engine:self routeLink:request opener:nil];
}

+ (void)openDeviceChooserSettings:(int)chooserId {
  airc::OpenDeviceChooserSettings(chooserId);
}

+ (void)resolveExtensionInstallPrompt:(NSString*)requestId accepted:(BOOL)accepted {
  airc::ResolveExtensionInstallPrompt(base::SysNSStringToUTF8(requestId), accepted);
}

- (void)deleteUnloadedProfileDirectory:(NSString*)directoryName
                            completion:(void (^)(NSDictionary*))completion {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  ProfileManager* manager = g_browser_process->profile_manager();
  if (!directoryName.length || [directoryName hasPrefix:@"."] ||
      [directoryName containsString:@"/"] ||
      [directoryName rangeOfString:[NSString stringWithFormat:@"%C", (unichar)0]].location != NSNotFound) {
    completion(@{@"deleted": @NO, @"reason": @"invalid directory name"}); return;
  }
  auto path = manager->user_data_dir().Append(base::SysNSStringToUTF8(directoryName));
  if (path.BaseName() == ProfileManager::GetInitialProfileDir() ||
      [directoryName caseInsensitiveCompare:@"Default"] == NSOrderedSame ||
      [directoryName caseInsensitiveCompare:@"System Profile"] == NSOrderedSame ||
      [directoryName caseInsensitiveCompare:@"Guest Profile"] == NSOrderedSame ||
      manager->GetProfileByPath(path) || SessionProfiles().contains(path)) {
    completion(@{@"deleted": @NO, @"reason": @"default, reserved or session-loaded profile"}); return;
  }
  // Filesystem validation is blocking; perform it off the UI sequence, then
  // recheck session ownership before the atomic rename on the UI sequence.
  auto tombstone = manager->user_data_dir().Append(
      ".airc-deleted-" + base::SysNSStringToUTF8(NSUUID.UUID.UUIDString));
  base::ThreadPool::PostTaskAndReplyWithResult(FROM_HERE,
      {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
      base::BindOnce([](base::FilePath path) {
        return !base::IsLink(path) && base::DirectoryExists(path) &&
            base::PathExists(path.AppendASCII("Preferences"));
      }, path),
      base::BindOnce([](base::FilePath path, base::FilePath tombstone,
                       void (^done)(NSDictionary*), bool valid) {
        if (!valid) { done(@{@"deleted": @NO, @"reason": @"missing profile folder or symlink"}); return; }
        NSString* name = base::SysUTF8ToNSString(path.BaseName().value()).precomposedStringWithCanonicalMapping;
        for (const auto& seen : SessionProfiles()) {
          NSString* other = base::SysUTF8ToNSString(seen.BaseName().value()).precomposedStringWithCanonicalMapping;
          if ([name caseInsensitiveCompare:other] == NSOrderedSame) {
            done(@{@"deleted": @NO, @"reason": @"session-loaded profile alias"}); return;
          }
        }
        auto* manager = g_browser_process->profile_manager();
        if (manager->GetProfileByPath(path) || rename(path.value().c_str(), tombstone.value().c_str()) != 0) {
          done(@{@"deleted": @NO, @"reason": @"profile loaded or folder rename failed"}); return;
        }
        auto& attributes = manager->GetProfileAttributesStorage();
        if (attributes.GetProfileAttributesWithPath(path)) attributes.RemoveProfile(path);
        base::ThreadPool::PostTaskAndReplyWithResult(FROM_HERE,
            {base::MayBlock(), base::TaskPriority::USER_VISIBLE, base::TaskShutdownBehavior::BLOCK_SHUTDOWN},
            base::BindOnce(&base::DeletePathRecursively, tombstone),
            base::BindOnce([](void (^done)(NSDictionary*), base::FilePath retained, bool ok) {
              done(@{@"deleted": @(ok), @"reason": ok ? @"" : @"quarantined folder removal failed",
                     @"retainedDirectory": ok ? @"" : base::SysUTF8ToNSString(retained.BaseName().value())});
            }, [done copy], tombstone));
      }, path, tombstone, [completion copy]));
}

- (void)deleteProfile:(AircProfile*)profile completion:(void (^)(BOOL deleted))completion {
  Profile* chrome_profile = profile.chromeProfile;
  ProfileManager* manager = g_browser_process->profile_manager();
  if (!chrome_profile || !chrome_profile->IsRegularProfile() ||
      chrome_profile->GetPath() ==
          manager->user_data_dir().Append(ProfileManager::GetInitialProfileDir())) {
    if (completion) {
      completion(NO);
    }
    return;
  }
  airc::DeleteProfilePasskeys(chrome_profile, base::BindOnce(
      [](AircProfile* profile, void (^completion)(BOOL), bool ok) {
        Profile* chrome_profile = profile.chromeProfile;
        if (!ok || !chrome_profile) {
          if (completion) completion(NO);
          return;
        }
        ProfileManager* manager = g_browser_process->profile_manager();
        airc::NoteProfileDeleting(chrome_profile);
        base::WeakPtr<Profile> weak = chrome_profile->GetWeakPtr();
        const base::FilePath path = chrome_profile->GetPath();
        manager->GetDeleteProfileHelper().MaybeScheduleProfileForDeletion(
            chrome_profile->GetPath(), base::DoNothing(),
            ProfileMetrics::DELETE_PROFILE_SETTINGS);
        if (weak) {
          manager->ClearFirstBrowserWindowKeepAlive(weak.get());
        }
        for (const base::TimeDelta delay : {base::Seconds(2), base::Seconds(10)}) {
          content::GetUIThreadTaskRunner({})->PostDelayedTask(
              FROM_HERE, base::BindOnce([](const base::FilePath& dir) {
                if (!IsProfileDirectoryMarkedForDeletion(dir) ||
                    g_browser_process->profile_manager()->GetProfileByPath(dir)) {
                  return;
                }
                base::ThreadPool::PostTask(
                    FROM_HERE,
                    {base::MayBlock(), base::TaskPriority::BEST_EFFORT,
                     base::TaskShutdownBehavior::SKIP_ON_SHUTDOWN},
                    base::BindOnce(base::IgnoreResult(&base::DeletePathRecursively), dir));
              }, path),
              delay);
        }
        if (completion) {
          completion(YES);
        }
      }, profile, [completion copy]));
}

- (void)releaseProfile:(AircProfile*)profile {
  Profile* chrome_profile = profile.chromeProfile;
  if (!chrome_profile || !chrome_profile->IsOffTheRecord()) {
    return;
  }
  bool in_use = false;
  GlobalBrowserCollection::GetInstance()->ForEach([&](BrowserWindowInterface* browser) {
    in_use |= browser->GetProfile() == chrome_profile &&
              !browser->capabilities()->IsAttemptingToCloseBrowser();
    return !in_use;
  });
  if (!in_use) {
    ProfileDestroyer::DestroyOTRProfileWhenAppropriate(chrome_profile);
  }
}

+ (void)allowDesktopCapture:(NSString*)sourceId
                        tab:(AircTab*)tab
                      frame:(NSString*)frameId
                     origin:(NSString*)origin
                      audio:(NSString*)audio {
  airc::AllowDesktopCapture(tab.contents, base::SysNSStringToUTF8(sourceId ?: @""),
                              base::SysNSStringToUTF8(frameId ?: @""),
                              base::SysNSStringToUTF8(origin ?: @""),
                              base::SysNSStringToUTF8(audio ?: @""));
}

+ (NSDictionary<NSString*, NSNumber*>*)desktopCaptureAudio {
  return @{
    @"system" : @(airc::IsDesktopCaptureSystemAudioSupported()),
    @"application" : @(airc::IsDesktopCaptureApplicationAudioSupported()),
  };
}

+ (NSArray<NSDictionary*>*)testExternalLaunches {
  return airc::TestExternalLaunches();
}

+ (NSArray<NSDictionary*>*)testChooserEvents {
  return airc::TestChooserEvents();
}

+ (void)resolveExternalApp:(NSString*)requestId open:(BOOL)open remember:(BOOL)remember {
  airc::ResolveExternalApp(base::SysNSStringToUTF8(requestId), open, remember);
}

- (void)offTheRecordProfileFor:(AircProfile*)profile
                    completion:(void (^)(AircProfile*, NSString*))completion {
  Profile* original = profile.chromeProfile;
  if (!original || original->IsOffTheRecord()) {
    completion(nil, original ? @"not a regular profile" : @"the profile went");
    return;
  }
  Profile* current = original->GetPrimaryOTRProfile(false);
  if (current && airc::IsProfileDying(current)) {
    airc::WhenProfileGone(current, base::BindOnce(^{
                              [self offTheRecordProfileFor:profile completion:completion];
                            }));
    return;
  }
  AircProfile* otr =
      [AircProfile wrapperFor:original->GetPrimaryOTRProfile(true)];
  if (otr) {
    // DownloadBubbleUIControllerDelegate sets an OTR-only prompt override when
    // the download service starts. Airc owns the downloads UI: initialize first,
    // then remove that override so the parent's live preference is inherited.
    // Keep Chromium's target validation and explicit Save As handling intact.
    DownloadPrefs::FromBrowserContext(otr.chromeProfile);
    otr.chromeProfile->GetPrefs()->ClearPref(prefs::kPromptForDownload);
  }
  completion(otr, otr ? nil : @"Chrome is destroying it");
}

- (NSString*)keepAliveState {
  std::ostringstream out;
  out << *KeepAliveRegistry::GetInstance()
      << " trying_to_quit=" << browser_shutdown::IsTryingToQuit();
  return NS(out.str());
}

- (NSString*)chromiumVersion {
  return NS(std::string(version_info::GetVersionNumber()));
}

@end

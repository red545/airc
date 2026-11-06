// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#import "airc/core/public/Airc.h"
#include "airc/core/airc_drm_policy.h"
#include "base/check.h"
#include "base/functional/callback_helpers.h"
#include "base/strings/sys_string_conversions.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/common/pref_names.h"
#include "components/component_updater/component_updater_service.h"
#include "components/prefs/pref_service.h"
#include "components/update_client/crx_update_item.h"
#include "content/public/browser/browser_thread.h"

namespace airc {
bool ProtectedContentEnabled() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto* prefs = g_browser_process ? g_browser_process->local_state() : nullptr;
  return prefs && prefs->GetBoolean(kProtectedContentPref);
}
}

@implementation AircEngine (ProtectedContent)
- (BOOL)protectedContentEnabled {
  return airc::ProtectedContentEnabled();
}
- (void)setProtectedContentEnabled:(BOOL)enabled {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  CHECK(g_browser_process && g_browser_process->local_state());
  const bool was_enabled = airc::ProtectedContentEnabled();
  g_browser_process->local_state()->SetBoolean(airc::kProtectedContentPref, enabled);
  for (Profile* profile : g_browser_process->profile_manager()->GetLoadedProfiles()) {
    profile->GetPrefs()->SetBoolean(prefs::kEnableEncryptedMedia, enabled);
  }
  if (enabled && !was_enabled) {
    g_browser_process->component_updater()->MaybeThrottle(
        airc::kWidevineComponentId, base::DoNothing());
  }
  // Renderer preference observers pick up the change. Existing MediaKeys and
  // an already-running component download need reload/restart to be torn down.
}
- (NSDictionary<NSString*, id>*)protectedContentState {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto* updater = g_browser_process->component_updater();
  NSString* version = @"";
  NSMutableArray* ids = [NSMutableArray array];
  NSMutableArray* components = [NSMutableArray array];
  for (const auto& component : updater->GetComponents()) {
    [ids addObject:[NSString stringWithUTF8String:component.id.c_str()]];
    [components addObject:@{@"id":ids.lastObject,
                            @"name":base::SysUTF16ToNSString(component.name),
                            @"version":[NSString stringWithUTF8String:component.version.GetString().c_str()]}];
    if (component.id == airc::kWidevineComponentId && component.version.IsValid())
      version = [NSString stringWithUTF8String:component.version.GetString().c_str()];
  }
  update_client::CrxUpdateItem item;
  const bool has_status = updater->GetComponentDetails(airc::kWidevineComponentId, &item);
  return @{ @"updateState": @(has_status ? static_cast<int>(item.state) : -1),
            @"updateErrorCategory": @(static_cast<int>(item.error_category)),
            @"updateErrorCode": @(item.error_code), @"updateExtraCode": @(item.extra_code1),
            @"downloadedBytes": @(item.downloaded_bytes), @"totalBytes": @(item.total_bytes),
            @"enabled": @([self protectedContentEnabled]),
            @"cdmVersion": version,
            @"registeredComponents": ids, @"components": components, @"vmpCertified": @NO };
}
@end

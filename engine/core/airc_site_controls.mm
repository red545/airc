// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#import "airc/core/airc_internal.h"
#include <cmath>
#include <string>
#include "base/functional/bind.h"
#include "base/strings/sys_string_conversions.h"
#include "base/supports_user_data.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "chrome/browser/browsing_data/chrome_browsing_data_model_delegate.h"
#include "chrome/browser/usb/usb_chooser_context.h"
#include "chrome/browser/usb/usb_chooser_context_factory.h"
#include "chrome/browser/serial/serial_chooser_context.h"
#include "chrome/browser/serial/serial_chooser_context_factory.h"
#include "chrome/browser/hid/hid_chooser_context.h"
#include "chrome/browser/hid/hid_chooser_context_factory.h"
#include "components/content_settings/core/browser/host_content_settings_map.h"
#include "components/content_settings/core/browser/content_settings_registry.h"
#include "components/content_settings/core/browser/content_settings_info.h"
#include "components/browsing_data/content/browsing_data_model.h"
#include "content/public/browser/browsing_data_filter_builder.h"
#include "content/public/browser/browsing_data_remover.h"
#include "content/public/browser/host_zoom_map.h"
#include "content/public/browser/storage_partition.h"
#include "services/network/public/mojom/cookie_manager.mojom.h"
#include "components/content_settings/core/browser/website_settings_info.h"
#include "third_party/blink/public/common/page/page_zoom.h"
#include "url/origin.h"
#include "net/cookies/canonical_cookie.h"
#include "components/permissions/permission_util.h"
#include "components/content_settings/core/browser/permission_settings_registry.h"
namespace {
GURL Site(NSString* input) {
  GURL url(base::SysNSStringToUTF8(input));
  return url.is_valid() && url.SchemeIsHTTPOrHTTPS() && !url.has_username() && !url.has_password()
    ? url.DeprecatedGetOriginAsURL() : GURL();
}
const struct { NSString* key; ContentSettingsType type; } kPermissions[] = {
  {@"camera", ContentSettingsType::MEDIASTREAM_CAMERA}, {@"microphone", ContentSettingsType::MEDIASTREAM_MIC},
  {@"location", ContentSettingsType::GEOLOCATION}, {@"notifications", ContentSettingsType::NOTIFICATIONS},
  {@"popups", ContentSettingsType::POPUPS}, {@"clipboard", ContentSettingsType::CLIPBOARD_READ_WRITE},
  {@"sound", ContentSettingsType::SOUND}, {@"automaticDownloads", ContentSettingsType::AUTOMATIC_DOWNLOADS},
  {@"midi", ContentSettingsType::MIDI_SYSEX}, {@"usb", ContentSettingsType::USB_GUARD},
  {@"serial", ContentSettingsType::SERIAL_GUARD}, {@"hid", ContentSettingsType::HID_GUARD},
  {@"protectedContent", ContentSettingsType::PROTECTED_MEDIA_IDENTIFIER}};
NSString* State(ContentSetting value) {
  switch (value) {
    case CONTENT_SETTING_ALLOW: return @"allow";
    case CONTENT_SETTING_BLOCK: return @"block";
    case CONTENT_SETTING_ASK: return @"ask";
    default: return @"default";
  }
}
bool Managed(const content_settings::SettingInfo& info) {
  return info.source != content_settings::SettingSource::kUser && info.source != content_settings::SettingSource::kNone;
}
class SettingsObserver : public base::SupportsUserData::Data, public content_settings::Observer {
 public:
  explicit SettingsObserver(HostContentSettingsMap* map) : map_(map) { map_->AddObserver(this); }
  ~SettingsObserver() override { map_->RemoveObserver(this); }
  void OnContentSettingChanged(const ContentSettingsPattern&, const ContentSettingsPattern&,
      ContentSettingsTypeSet) override { if (handler) handler(@""); }
  void (^handler)(NSString*);
  scoped_refptr<HostContentSettingsMap> map_;
};
class ClearData : public content::BrowsingDataRemover::Observer {
 public:
  ClearData(content::BrowsingDataRemover* remover, void (^done)(BOOL)) : remover_(remover), done_([done copy]) { remover_->AddObserver(this); }
  void OnBrowsingDataRemoverDone(uint64_t failed) override {
    remover_->RemoveObserver(this); success_ &= failed == 0; Complete();
  }
  void Complete() {
    if (--pending_) return;
    auto done = done_; bool success = success_; delete this; done(success);
  }
  int pending_ = 2;
  bool success_ = true;
  raw_ptr<content::BrowsingDataRemover> remover_;
  void (^done_)(BOOL);
};
}
@implementation AircProfile (SiteControls)
- (NSDictionary*)sitePermissions:(NSString*)origin {
  GURL url = Site(origin); if (!self.chromeProfile || url.is_empty()) return @{};
  auto* map = HostContentSettingsMapFactory::GetForProfile(self.chromeProfile);
  NSMutableDictionary* result = [NSMutableDictionary dictionary];
  for (const auto& permission : kPermissions) {
    auto type = [permission.key isEqual:@"location"] ? permissions::PermissionUtil::GetGeolocationType() : permission.type;
    if (!content_settings::PermissionSettingsRegistry::GetInstance()->Get(type)) continue;
    content_settings::SettingInfo info;
    auto setting = map->GetPermissionSetting(url, url, type, &info);
    ContentSetting value;
    if (auto* simple = std::get_if<ContentSetting>(&setting)) value = *simple;
    else {
      auto geo = std::get<GeolocationSetting>(setting);
      value = geo.approximate == PermissionOption::kDenied ? CONTENT_SETTING_BLOCK :
        geo.approximate == PermissionOption::kAllowed ? CONTENT_SETTING_ALLOW : CONTENT_SETTING_ASK;
    }
    bool inherited = info.primary_pattern == ContentSettingsPattern::Wildcard() && info.secondary_pattern == ContentSettingsPattern::Wildcard();
    result[permission.key] = @{@"state": inherited ? @"default" : State(value), @"effective": State(value), @"managed": @(Managed(info))};
  }
  return result;
}
- (BOOL)setSitePermission:(NSString*)permission state:(NSString*)state origin:(NSString*)origin {
  GURL url = Site(origin); if (!self.chromeProfile || url.is_empty()) return NO;
  ContentSetting value = CONTENT_SETTING_DEFAULT;
  if ([state isEqual:@"ask"]) value = CONTENT_SETTING_ASK;
  else if ([state isEqual:@"allow"]) value = CONTENT_SETTING_ALLOW;
  else if ([state isEqual:@"block"]) value = CONTENT_SETTING_BLOCK;
  else if (![state isEqual:@"default"]) return NO;
  auto* map = HostContentSettingsMapFactory::GetForProfile(self.chromeProfile);
  for (const auto& p : kPermissions) if ([permission isEqual:p.key]) {
    auto type = [p.key isEqual:@"location"] ? permissions::PermissionUtil::GetGeolocationType() : p.type;
    if (type == ContentSettingsType::GEOLOCATION_WITH_OPTIONS) {
      content_settings::SettingInfo info; map->GetPermissionSetting(url, url, type, &info);
      if (Managed(info)) return NO;
      std::optional<PermissionSetting> setting;
      if (value != CONTENT_SETTING_DEFAULT) {
        auto option = value == CONTENT_SETTING_ALLOW ? PermissionOption::kAllowed :
          value == CONTENT_SETTING_BLOCK ? PermissionOption::kDenied : PermissionOption::kAsk;
        setting = GeolocationSetting{option, option};
      }
      map->SetPermissionSettingDefaultScope(url, url, type, setting); return YES;
    }
    auto* registered = content_settings::ContentSettingsRegistry::GetInstance()->Get(type);
    if (!registered || (value != CONTENT_SETTING_DEFAULT && !registered->IsSettingValid(value))) return NO;
    content_settings::SettingInfo info; map->GetContentSetting(url, url, p.type, &info);
    if (Managed(info)) return NO;
    map->SetContentSettingDefaultScope(url, url, p.type, value); return YES;
  }
  return NO;
}
- (BOOL)resetSitePermissions:(NSString*)origin {
  GURL url = Site(origin); auto* profile = self.chromeProfile;
  if (!profile || url.is_empty()) return NO;
  auto* map = HostContentSettingsMapFactory::GetForProfile(profile);
  for (const auto* registered : *content_settings::PermissionSettingsRegistry::GetInstance()) {
    auto type = registered->website_settings_info()->type();
    // Clear the registered scope used by the setter (some settings are host
    // scoped), plus exact-origin embedded grants. Preserve unrelated rules.
    map->SetPermissionSettingDefaultScope(url, url, type, std::nullopt);
    for (const auto& rule : map->GetSettingsForOneType(type)) {
      if (rule.source == content_settings::ProviderType::kPrefProvider &&
          rule.primary_pattern == ContentSettingsPattern::FromURLNoWildcard(url) &&
          rule.secondary_pattern.Matches(url))
        map->SetPermissionSettingCustomScope(rule.primary_pattern, rule.secondary_pattern, type, std::nullopt);
    }
  }
  auto site = url::Origin::Create(url);
  if (auto* context = UsbChooserContextFactory::GetForProfile(profile)) context->RevokeObjectPermissions(site);
  if (auto* context = SerialChooserContextFactory::GetForProfile(profile)) context->RevokeObjectPermissions(site);
  if (auto* context = HidChooserContextFactory::GetForProfile(profile)) context->RevokeObjectPermissions(site);
  return YES;
}
- (void)observeSitePermissions:(void (^)(NSString*))handler {
  if (!self.chromeProfile) return;
  static int key;
  auto* state = static_cast<SettingsObserver*>(self.chromeProfile->GetUserData(&key));
  if (!state) {
    auto owned = std::make_unique<SettingsObserver>(HostContentSettingsMapFactory::GetForProfile(self.chromeProfile));
    state = owned.get(); self.chromeProfile->SetUserData(&key, std::move(owned));
  }
  state->handler = [handler copy];
}
- (void)siteData:(NSString*)origin completion:(void (^)(NSDictionary*))completion {
  GURL url = Site(origin); auto* profile = self.chromeProfile;
  if (!profile || url.is_empty()) { completion(@{@"valid": @NO}); return; }
  BrowsingDataModel::BuildFromDisk(profile, ChromeBrowsingDataModelDelegate::CreateForProfile(profile),
    base::BindOnce([](url::Origin site, void (^done)(NSDictionary*), std::unique_ptr<BrowsingDataModel> model) {
      uint64_t bytes = 0, cookies = 0;
      for (const auto entry : *model) if (
        std::holds_alternative<net::CanonicalCookie>(*entry.data_key)
          ? std::get<net::CanonicalCookie>(*entry.data_key).IsDomainMatch(site.host())
          : BrowsingDataModel::GetOriginForDataKey(*entry.data_key) == site) {
        bytes += entry.data_details->storage_size; cookies += entry.data_details->cookie_count;
      }
      done(@{@"valid": @YES, @"cookies": @(cookies), @"storageBytes": @(bytes)});
    }, url::Origin::Create(url), [completion copy]));
}
- (void)clearSiteData:(NSString*)origin completion:(void (^)(BOOL))completion {
  GURL url = Site(origin); auto* profile = self.chromeProfile;
  if (!profile || url.is_empty()) { completion(NO); return; }
  auto filter = content::BrowsingDataFilterBuilder::Create(content::BrowsingDataFilterBuilder::Mode::kDelete);
  filter->AddOrigin(url::Origin::Create(url));
  auto* remover = profile->GetBrowsingDataRemover();
  auto* observer = new ClearData(remover, completion);
  auto* cookies = profile->GetDefaultStoragePartition()->GetCookieManagerForBrowserProcess();
  cookies->GetAllCookies(base::BindOnce([](ClearData* pending, network::mojom::CookieManager* manager,
      std::string host, const net::CookieList& list) {
    for (const auto& cookie : list) if (cookie.IsDomainMatch(host)) {
      ++pending->pending_;
      manager->DeleteCanonicalCookie(cookie, base::BindOnce([](ClearData* pending, bool ok) {
        pending->success_ &= ok; pending->Complete();
      }, pending));
    }
    pending->Complete();
  }, observer, cookies, std::string(url.host())));
  remover->RemoveWithFilterAndReply(base::Time(), base::Time::Max(),
    content::BrowsingDataRemover::DATA_TYPE_DOM_STORAGE | content::BrowsingDataRemover::DATA_TYPE_MEDIA_LICENSES,
    content::BrowsingDataRemover::ORIGIN_TYPE_UNPROTECTED_WEB | content::BrowsingDataRemover::ORIGIN_TYPE_PROTECTED_WEB,
    std::move(filter), observer);
}
- (double)defaultSiteZoomFactor {
  return self.chromeProfile ? blink::ZoomLevelToZoomFactor(content::HostZoomMap::GetDefaultForBrowserContext(self.chromeProfile)->GetDefaultZoomLevel()) : 1;
}
- (double)siteZoomFactor:(NSString*)origin {
  GURL url = Site(origin); if (!self.chromeProfile || url.is_empty()) return self.defaultSiteZoomFactor;
  return blink::ZoomLevelToZoomFactor(content::HostZoomMap::GetDefaultForBrowserContext(self.chromeProfile)->GetZoomLevelForHostAndScheme(std::string(url.scheme()), std::string(url.host())));
}
- (BOOL)setSiteZoomFactor:(double)factor origin:(NSString*)origin {
  GURL url = Site(origin);
  if (!self.chromeProfile || url.is_empty() || !std::isfinite(factor) || factor < 0.25 || factor > 5) return NO;
  content::HostZoomMap::GetDefaultForBrowserContext(self.chromeProfile)->SetZoomLevelForHost(std::string(url.host()), blink::ZoomFactorToZoomLevel(factor)); return YES;
}
- (BOOL)resetSiteZoom:(NSString*)origin { return [self setSiteZoomFactor:self.defaultSiteZoomFactor origin:origin]; }
@end

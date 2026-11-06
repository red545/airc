// Copyright 2026 The Airc Authors
// SPDX-License-Identifier: Apache-2.0
#import "airc/core/public/Airc.h"
#import "airc/core/airc_internal.h"
#include <algorithm>
#include <set>
#include <deque>
#include <map>
#include "components/download/public/common/download_url_parameters.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "base/no_destructor.h"
#include "base/memory/weak_ptr.h"
#include "base/task/sequenced_task_runner.h"
#include "components/password_manager/core/browser/password_store/password_store_consumer.h"
#include "content/public/browser/download_manager.h"
#include "components/download/public/common/download_item.h"
#include "base/functional/bind.h"
#include "base/strings/sys_string_conversions.h"
#include "base/supports_user_data.h"
#include "base/task/cancelable_task_tracker.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/history/history_service_factory.h"
#include "chrome/browser/signin/identity_manager_factory.h"
#include "chrome/browser/password_manager/factories/profile_password_store_factory.h"
#include "components/history/core/browser/history_service.h"
#include "components/history/core/browser/history_service_observer.h"
#include "components/password_manager/core/browser/password_store/password_store_interface.h"
#include "components/password_manager/core/browser/password_store/stored_credential.h"
#include "components/password_manager/core/browser/password_store/password_form_converters.h"
#include "components/password_manager/core/browser/password_form_digest.h"
#include "components/signin/public/identity_manager/identity_manager.h"
#include "components/signin/public/identity_manager/accounts_in_cookie_jar_info.h"
#include "content/public/browser/storage_partition.h"
#include "net/cookies/canonical_cookie.h"
#include "net/cookies/cookie_access_result.h"
#include "services/network/public/mojom/cookie_manager.mojom.h"

namespace {
NSString* String(NSDictionary* row, NSString* key) {
  return [row[key] isKindOfClass:NSString.class] ? row[key] : @"";
}
// Serial imports per store avoid two import batches overwriting each other.
// Read before adding, then verify persisted contents: AddLogin has no result.
class LoginImport : public password_manager::PasswordStoreConsumer {
 public:
  using Store = password_manager::PasswordStoreInterface;
  using Credential = password_manager::StoredCredential;
  using Queue = std::deque<std::unique_ptr<LoginImport>>;
  static auto& Queues() {
    static base::NoDestructor<std::map<Store*, Queue>> queues;
    return *queues;
  }
  static void Run(scoped_refptr<Store> store, NSArray* rows,
                  void (^done)(NSDictionary*)) {
    auto* key = store.get();
    auto& queue = Queues()[key];
    queue.push_back(std::make_unique<LoginImport>(std::move(store), rows, done));
    if (queue.size() == 1) queue.front()->Next();
  }
  LoginImport(scoped_refptr<Store> store, NSArray* rows,
              void (^done)(NSDictionary*))
      : store_(std::move(store)), rows_([rows copy]), done_([done copy]),
        results_([NSMutableArray array]) {}
  void Next() {
    if (index_ == rows_.count) {
      NSUInteger saved = 0, skipped = 0;
      for (NSDictionary* row in results_) {
        saved += [row[@"status"] isEqual:@"saved"];
        skipped += [row[@"status"] isEqual:@"skipped-duplicate"];
      }
      auto done = done_;
      NSDictionary* result = @{@"saved": @(saved), @"skipped": @(skipped),
          @"rejected": @(rows_.count - saved - skipped), @"results": results_};
      auto* key = store_.get();
      // Keep this consumer alive through callback/reentrancy and queue advancement.
      auto owned = std::move(Queues()[key].front());
      Queues()[key].pop_front();
      bool next = !Queues()[key].empty();
      if (!next) Queues().erase(key);
      if (next) Queues()[key].front()->Next();
      done(result);
      return;
    }
    NSDictionary* row = rows_[index_];
    GURL url(base::SysNSStringToUTF8(String(row, @"origin")));
    GURL realm(base::SysNSStringToUTF8(String(row, @"signonRealm")));
    if (!url.SchemeIsHTTPOrHTTPS() || !realm.SchemeIsHTTPOrHTTPS() ||
        url.DeprecatedGetOriginAsURL() != realm ||
        ![row[@"password"] isKindOfClass:NSString.class]) {
      Record(@"rejected", @"invalid HTTP(S) origin, realm or password"); return;
    }
    form_ = std::make_unique<Credential>();
    form_->url = url; form_->signon_realm = realm.spec();
    form_->action = GURL(base::SysNSStringToUTF8(String(row, @"actionURL")));
    form_->username_value = base::SysNSStringToUTF16(String(row, @"username"));
    form_->password_value = password_manager::PasswordString(base::SysNSStringToUTF16(row[@"password"]));
    form_->date_created = base::Time::Now();
    verifying_ = false;
    Read();
  }
  void Read() {
    store_->GetLogins(password_manager::PasswordFormDigest(form_->scheme, form_->signon_realm, form_->url), weak_.GetWeakPtr());
  }
  void Record(NSString* status, NSString* reason) {
    [results_ addObject:@{@"index": @(index_++), @"status": status, @"reason": reason}];
    form_.reset();
    // Avoid recursive stack growth on a large invalid batch.
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&LoginImport::Next, weak_.GetWeakPtr()));
  }
  void OnGetPasswordStoreResultsOrErrorFrom(Store*,
      base::expected<std::vector<Credential>, password_manager::PasswordStoreBackendError> rows) override {
    if (!rows.has_value()) { Record(@"rejected", @"password store read failed"); return; }
    for (const auto& row : rows.value()) {
      if (!password_manager::AreStoredCredentialUniqueKeysEqual(row, *form_)) continue;
      if (!verifying_) { Record(@"skipped-duplicate", @"existing login key preserved"); return; }
      bool matches = !row.blocked_by_user && row.password_value == form_->password_value;
      Record(matches ? @"saved" : @"rejected", matches ? @"" : @"password store readback mismatch");
      return;
    }
    if (verifying_) { Record(@"rejected", @"password store did not persist login"); return; }
    verifying_ = true;
    store_->AddLogin(password_manager::CloneStoredCredential(*form_),
        base::BindOnce([](base::WeakPtr<LoginImport> self) {
          if (self) self->Read();
        }, weak_.GetWeakPtr()));
  }
 private:
  scoped_refptr<Store> store_;
  NSArray* __strong rows_;
  void (^done_)(NSDictionary*);
  NSMutableArray* __strong results_;
  NSUInteger index_ = 0;
  bool verifying_ = false;
  std::unique_ptr<Credential> form_;
  base::WeakPtrFactory<LoginImport> weak_{this};
};
NSDictionary* HistoryRow(const history::URLRow& row) {
  return @{@"url": base::SysUTF8ToNSString(row.url().spec()),
           @"title": base::SysUTF16ToNSString(row.title()),
           @"visits": @(row.visit_count()),
           @"lastVisit": @(row.last_visit().InSecondsFSinceUnixEpoch())};
}
bool CanKeepDownload(download::DownloadItem* item) {
  if (item->IsDone()) return false;
  switch (item->GetDangerType()) {
    case download::DOWNLOAD_DANGER_TYPE_DANGEROUS_FILE:
    case download::DOWNLOAD_DANGER_TYPE_DANGEROUS_URL:
    case download::DOWNLOAD_DANGER_TYPE_DANGEROUS_CONTENT:
    case download::DOWNLOAD_DANGER_TYPE_UNCOMMON_CONTENT:
    case download::DOWNLOAD_DANGER_TYPE_DANGEROUS_HOST:
    case download::DOWNLOAD_DANGER_TYPE_POTENTIALLY_UNWANTED:
    case download::DOWNLOAD_DANGER_TYPE_SENSITIVE_CONTENT_WARNING:
    case download::DOWNLOAD_DANGER_TYPE_DANGEROUS_ACCOUNT_COMPROMISE:
      return true;
    default: return false; // Never bypass enterprise blocks or scanning workflows.
  }
}
NSDictionary* DownloadRow(download::DownloadItem* item) {
  return @{@"id": base::SysUTF8ToNSString(item->GetGuid()),
    @"url": base::SysUTF8ToNSString(item->GetURL().spec()),
    @"path": base::SysUTF8ToNSString(item->GetTargetFilePath().value()),
    @"received": @(item->GetReceivedBytes()), @"total": @(item->GetTotalBytes()),
    @"state": @(static_cast<int>(item->GetState())), @"paused": @(item->IsPaused()),
    @"dangerous": @(item->IsDangerous()),
    @"fileName": base::SysUTF8ToNSString(item->GetFileNameToReportUser().value()),
    @"mimeType": base::SysUTF8ToNSString(item->GetMimeType()),
    @"startTime": @(item->GetStartTime().is_null() ? 0 : item->GetStartTime().InSecondsFSinceUnixEpoch()),
    @"endTime": @(item->GetEndTime().is_null() ? 0 : item->GetEndTime().InSecondsFSinceUnixEpoch()),
    @"referrer": base::SysUTF8ToNSString(item->GetReferrerUrl().spec()),
    @"interruptReason": @(static_cast<int>(item->GetLastReason())),
    @"canResume": @(item->CanResume()), @"canKeep": @(CanKeepDownload(item)),
    @"dangerType": @(static_cast<int>(item->GetDangerType())), @"openWhenComplete": @(item->GetOpenWhenComplete())};
}
class Services : public base::SupportsUserData::Data,
                 public history::HistoryServiceObserver,
                 public content::DownloadManager::Observer, public download::DownloadItem::Observer {
 public:
  explicit Services(AircProfile* wrapper) : wrapper_(wrapper) {
    history_ = wrapper.offTheRecord ? nullptr : HistoryServiceFactory::GetForProfile(wrapper.chromeProfile,
                                                   ServiceAccessType::EXPLICIT_ACCESS);
    if (history_) history_->AddObserver(this);
  }
  ~Services() override {
    if (history_) history_->RemoveObserver(this);
    if (downloads_) downloads_->RemoveObserver(this);
    for (auto* item : items_) item->RemoveObserver(this);
  }
  void OnDownloadCreated(content::DownloadManager*, download::DownloadItem* item) override {
    if (items_.insert(item).second) item->AddObserver(this);
    OnDownloadUpdated(item);
  }
  void OnDownloadUpdated(download::DownloadItem* item) override {
    if (download_) download_(DownloadRow(item));
  }
  void OnDownloadRemoved(download::DownloadItem* item) override {
    NSMutableDictionary* row = [DownloadRow(item) mutableCopy];
    row[@"removed"] = @YES;
    if (download_) download_(row);
  }

  void OnDownloadDestroyed(download::DownloadItem* item) override {
    item->RemoveObserver(this); items_.erase(item);
  }
  void ManagerGoingDown(content::DownloadManager*) override {
    downloads_->RemoveObserver(this); downloads_ = nullptr;
  }
  void HistoryServiceBeingDeleted(history::HistoryService*) override {
    history_->RemoveObserver(this);
    history_ = nullptr;
  }
  void OnURLVisited(history::HistoryService*, const history::VisitedURLInfo& info) override {
    if (visit_) {
      NSMutableDictionary* row = [HistoryRow(info.url_row) mutableCopy];
      row[@"visitID"] = @(info.visit_row.visit_id);
      row[@"time"] = @(info.visit_row.visit_time.InSecondsFSinceUnixEpoch());
      visit_(row);
    }
  }
  static Services* Get(AircProfile* profile) {
    if (!profile.chromeProfile) return nullptr;
    static const int key = 0;
    auto* service = static_cast<Services*>(profile.chromeProfile->GetUserData(&key));
    if (!service) {
      auto owned = std::make_unique<Services>(profile);
      service = owned.get();
      profile.chromeProfile->SetUserData(&key, std::move(owned));
    }
    return service;
  }
  void WatchDownloads() {
    if (downloads_ || !wrapper_.chromeProfile) return;
    downloads_ = wrapper_.chromeProfile->GetDownloadManager();
    downloads_->AddObserver(this);
    content::DownloadManager::DownloadVector existing;
    downloads_->GetAllDownloads(&existing);
    for (const auto& item : existing) OnDownloadCreated(downloads_, item.get());
  }
  raw_ptr<content::DownloadManager> downloads_ = nullptr;
  std::set<download::DownloadItem*> items_;
  void (^download_)(NSDictionary*);
  __weak AircProfile* wrapper_;
  void (^visit_)(NSDictionary*);
  raw_ptr<history::HistoryService> history_ = nullptr;
  base::CancelableTaskTracker tracker_;
};
}

@implementation AircProfile (Services)
- (void)observeDownloads:(void (^)(NSDictionary*))handler {
  if (auto* service = Services::Get(self)) {
    service->download_ = [handler copy];
    bool watching = service->downloads_ != nullptr;
    service->WatchDownloads();
    if (watching && handler) {
      for (auto* item : service->items_) handler(DownloadRow(item));
    }
  }
}
- (void)observeHistoryVisits:(void (^)(NSDictionary*))handler {
  if (auto* service = Services::Get(self)) service->visit_ = [handler copy];
}
- (void)queryHistory:(NSString*)query limit:(NSInteger)limit
         completion:(void (^)(NSArray<NSDictionary*>*))completion {
  auto* service = Services::Get(self);
  if (!service || !service->history_) { completion(@[]); return; }
  history::QueryOptions options;
  options.max_count = std::clamp<NSInteger>(limit, 1, 1000);
  service->history_->QueryHistory(base::SysNSStringToUTF16(query), options,
      base::BindOnce([](void (^done)(NSArray*), history::QueryResults results) {
        NSMutableArray* rows = [NSMutableArray array];
        for (const auto& row : results) [rows addObject:HistoryRow(row)];
        done(rows);
      }, [completion copy]), &service->tracker_);
}
- (NSDictionary*)googleAccounts {
  auto* manager = self.chromeProfile ? IdentityManagerFactory::GetForProfile(self.chromeProfile) : nullptr;
  if (!manager) return @{@"fresh": @NO, @"accounts": @[]};
  const auto info = manager->GetAccountsInCookieJar();
  NSMutableArray* accounts = [NSMutableArray array];
  for (const auto& account : info.GetValidSignedInAccounts()) {
    [accounts addObject:@{@"id": base::SysUTF8ToNSString(account.gaia_id.ToString()),
                          @"email": base::SysUTF8ToNSString(account.email)}];
  }
  return @{@"fresh": @(info.AreAccountsFresh()), @"accounts": accounts};
}
- (void)importLogins:(NSArray<NSDictionary*>*)logins
         completion:(void (^)(NSDictionary*))completion {
  auto store = self.chromeProfile && !self.offTheRecord
      ? ProfilePasswordStoreFactory::GetForProfile(self.chromeProfile, ServiceAccessType::EXPLICIT_ACCESS)
      : nullptr;
  if (!store) {
    NSMutableArray* results = [NSMutableArray array];
    for (NSUInteger i = 0; i < logins.count; ++i)
      [results addObject:@{@"index": @(i), @"status": @"rejected", @"reason": @"store unavailable"}];
    completion(@{@"saved": @0, @"skipped": @0, @"rejected": @(logins.count), @"results": results}); return;
  }
  LoginImport::Run(std::move(store), logins, completion);
}
- (void)importCookies:(NSArray<NSDictionary*>*)cookies
          completion:(void (^)(NSDictionary*))completion {
  NSMutableArray* results = [NSMutableArray array];
  for (NSUInteger i = 0; i < cookies.count; ++i) [results addObject:NSNull.null];
  if (!cookies.count) { completion(@{@"accepted": @0, @"rejected": @0, @"results": results}); return; }
  __block NSUInteger pending = cookies.count, accepted = 0;
  void (^done)(NSUInteger, NSString*) = ^(NSUInteger index, NSString* reason) {
    BOOL ok = reason.length == 0;
    accepted += ok;
    results[index] = @{@"index": @(index), @"status": ok ? @"accepted" : @"rejected", @"reason": reason};
    if (!--pending) completion(@{@"accepted": @(accepted), @"rejected": @(cookies.count - accepted), @"results": results});
  };
  auto* manager = self.chromeProfile && !self.offTheRecord
      ? self.chromeProfile->GetDefaultStoragePartition()->GetCookieManagerForBrowserProcess() : nullptr;
  for (NSUInteger index = 0; index < cookies.count; ++index) {
    if (!manager) { done(index, @"store unavailable"); continue; }
    NSDictionary* row = cookies[index];
    NSString* host = String(row, @"host");
    NSString* domain = [host hasPrefix:@"."] ? host : @"";
    NSString* sourceHost = [host hasPrefix:@"."] ? [host substringFromIndex:1] : host;
    GURL source(base::SysNSStringToUTF8([NSString stringWithFormat:@"%@://%@/",
        [row[@"secure"] boolValue] ? @"https" : @"http", sourceHost]));
    if (!source.is_valid() || source.has_username() || source.has_password() || source.has_port() ||
        source.path() != "/" || source.has_query() || source.has_ref() || !sourceHost.length) {
      done(index, @"invalid domain"); continue;
    }
    NSDictionary* metadata = [row[@"metadata"] isKindOfClass:NSDictionary.class] ? row[@"metadata"] : @{};
    if ([String(metadata, @"top_frame_site_key") length] || [String(metadata, @"partition_key") length]) {
      done(index, @"partitioned cookie unsupported"); continue;
    }
    int sameSite = [row[@"sameSite"] intValue];
    int64_t expiry = [row[@"expiresUTC"] longLongValue];
    if (sameSite < -1 || sameSite > 2) { done(index, @"invalid SameSite"); continue; }
    base::Time expires = expiry ? base::Time::FromDeltaSinceWindowsEpoch(base::Microseconds(expiry)) : base::Time();
    if (expiry < 0 || (expiry && expires <= base::Time::Now())) { done(index, @"expired cookie"); continue; }
    net::CookieInclusionStatus status;
    auto cookie = net::CanonicalCookie::CreateSanitizedCookie(source,
        base::SysNSStringToUTF8(String(row, @"name")), base::SysNSStringToUTF8(String(row, @"value")),
        base::SysNSStringToUTF8(domain), base::SysNSStringToUTF8(String(row, @"path")),
        base::Time::Now(), expires, base::Time::Now(), [row[@"secure"] boolValue], [row[@"httpOnly"] boolValue],
        static_cast<net::CookieSameSite>(sameSite), net::COOKIE_PRIORITY_MEDIUM, std::nullopt, &status);
    if (!cookie) { done(index, base::SysUTF8ToNSString(status.GetDebugString())); continue; }
    manager->SetCanonicalCookie(*cookie, source, net::CookieOptions::MakeAllInclusive(),
        base::BindOnce([](void (^done)(NSUInteger, NSString*), NSUInteger index, net::CookieAccessResult result) {
          done(index, result.status.IsInclude() ? @"" : base::SysUTF8ToNSString(result.status.GetDebugString()));
        }, [done copy], index));
  }
}
@end

@interface AircProfile (DownloadLibrary)
@end
@implementation AircProfile (DownloadLibrary)
- (NSArray<NSDictionary*>*)downloads {
  auto* service = Services::Get(self);
  if (!service) return @[];
  service->WatchDownloads();
  content::DownloadManager::DownloadVector items;
  service->downloads_->GetAllDownloads(&items);
  NSMutableArray* rows = [NSMutableArray array];
  for (auto& item : items) [rows addObject:DownloadRow(item.get())];
  return rows;
}
- (BOOL)performDownloadAction:(NSString*)action identifier:(NSString*)identifier {
  if (!self.chromeProfile) return NO;
  auto* manager = self.chromeProfile->GetDownloadManager();
  auto* item = manager->GetDownloadByGuid(base::SysNSStringToUTF8(identifier));
  if (!item) return NO;
  if ([action isEqual:@"pause"] && item->GetState() == download::DownloadItem::IN_PROGRESS) item->Pause();
  else if ([action isEqual:@"resume"] && item->CanResume()) item->Resume(true);
  else if ([action isEqual:@"cancel"] && !item->IsDone()) item->Cancel(true);
  else if ([action isEqual:@"remove"] && item->IsDone()) item->Remove();
  else if ([action isEqual:@"keep"] && CanKeepDownload(item)) item->ValidateDangerousDownload();
  else if ([action isEqual:@"discard"] && item->IsDangerous()) {
    item->Cancel(true);
    item->Remove(); // DownloadItem removes an unvalidated dangerous file on destruction.
  } else if ([action isEqual:@"open"] && !item->IsDangerous()) {
    if (item->GetState() == download::DownloadItem::IN_PROGRESS)
      item->SetOpenWhenComplete(!item->GetOpenWhenComplete());
    else if (item->GetState() == download::DownloadItem::COMPLETE && item->CanOpenDownload()) item->OpenDownload();
    else return NO;
  } else if ([action isEqual:@"retry"] && item->GetState() == download::DownloadItem::INTERRUPTED && !item->IsDangerous()) {
    if (item->CanResume()) item->Resume(true);
    else {
      if (!item->GetURL().SchemeIsHTTPOrHTTPS()) return NO;
      auto params = std::make_unique<download::DownloadUrlParameters>(item->GetURL(),
          net::DefineNetworkTrafficAnnotation("airc_download_retry", R"(
            semantics { sender: "Airc Downloads" description: "Retries a failed download."
              trigger: "User presses Retry in Downloads." data: "Original download URL."
              destination: WEBSITE }
            policy { cookies_allowed: YES cookies_store: "user"
              setting: "Explicit user action." policy_exception_justification: "User initiated download." })"));
      manager->DownloadUrl(std::move(params));
    }
  } else return NO;
  return YES;
}
- (NSString*)downloadPath:(NSString*)identifier {
  if (!self.chromeProfile) return nil;
  auto* item = self.chromeProfile->GetDownloadManager()->GetDownloadByGuid(base::SysNSStringToUTF8(identifier));
  if (!item || item->IsDangerous() || item->GetState() != download::DownloadItem::COMPLETE) return nil;
  return base::SysUTF8ToNSString(item->GetTargetFilePath().value());
}
@end

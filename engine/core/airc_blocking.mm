// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#import "airc/core/airc_internal.h"
#include "airc/core/airc_blocking.h"
#include "airc/core/airc_blocking_ffi.h"
#include <memory>
#include <map>
#include <string>
#include "base/functional/bind.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/synchronization/lock.h"
#include "crypto/sha2.h"
#include "components/content_settings/core/browser/cookie_settings.h"
#include "components/content_settings/core/common/pref_names.h"
#include "components/prefs/pref_service.h"
#include "extensions/browser/extension_registrar.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/extension_system.h"
#include "extensions/browser/management_policy.h"
#include "extensions/browser/disable_reason.h"
#include "extensions/common/extension.h"
#include "third_party/blink/public/common/loader/resource_type_util.h"
#include "base/strings/sys_string_conversions.h"
#include "base/supports_user_data.h"
#include "base/task/thread_pool.h"
#include "base/task/sequenced_task_runner.h"
#include "chrome/browser/profiles/profile.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/weak_document_ptr.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "mojo/public/cpp/bindings/receiver.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "net/base/isolation_info.h"
#include "net/base/net_errors.h"
#include "net/http/http_response_headers.h"
#include "services/network/public/cpp/content_security_policy/content_security_policy.h"
#include "services/network/public/mojom/parsed_headers.mojom.h"
#include "services/network/public/mojom/content_security_policy.mojom.h"
#include "net/url_request/redirect_info.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/self_deleting_url_loader_factory.h"
#include "services/network/public/cpp/url_loader_completion_status.h"
#include "services/network/public/cpp/url_loader_factory_builder.h"
#include "services/network/public/mojom/early_hints.mojom.h"
#include "services/network/public/mojom/url_response_head.mojom.h"

namespace airc {
namespace {
const int kProfileKey=0, kPageKey=0;
using Rules = std::shared_ptr<AircBlockingEngine>;
const uint8_t* Bytes(const std::string& value) { return reinterpret_cast<const uint8_t*>(value.data()); }
id JSONValue(AircBlockingBytes value) {
  if (!value.data) return @{};
  NSData* data = [NSData dataWithBytes:value.data length:value.len];
  airc_blocking_bytes_free(value);
  id result = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  return result;
}
std::string Host(const GURL& url) {
  if (!url.SchemeIsHTTPOrHTTPS() || !url.is_valid()) return {};
  std::string host(url.host());
  if (host.ends_with('.')) host.pop_back();
  return host;
}
NSDictionary* JSON(AircBlockingBytes value) {
  id result=JSONValue(value);
  return [result isKindOfClass:NSDictionary.class] ? result : @{};
}
// The cache retains weak references only. Profile deletion releases its lists;
// the next compile prunes expired entries. This lock never covers parsing.
Rules Compile(std::string text) {
  static base::NoDestructor<base::Lock> mutex;
  static base::NoDestructor<std::map<std::string,std::weak_ptr<AircBlockingEngine>>> cache;
  auto digest=crypto::SHA256HashString(text);
  {
    base::AutoLock lock(*mutex);
    if (auto existing=(*cache)[digest].lock()) return existing;
  }
  Rules result(airc_blocking_create(Bytes(text),text.size()),airc_blocking_destroy);
  if (result) {
    base::AutoLock lock(*mutex);
    if (auto existing=(*cache)[digest].lock()) return existing;
    std::erase_if(*cache,[](const auto& entry) { return entry.second.expired(); });
    (*cache)[digest]=result;
  }
  return result;
}
class ProfileBlocking final : public base::SupportsUserData::Data {
 public:
  bool enabled=false;
  std::optional<bool> enabled_override;
  uint64_t generation=0;
  Rules rules;
  bool inherit_exceptions=true;
  base::WeakPtr<ProfileBlocking> original;
  std::map<std::string,bool> exceptions;
  Rules ActiveRules() const { return rules ? rules : (original ? original->ActiveRules() : nullptr); }
  bool Enabled() const { return enabled_override.value_or(original ? original->Enabled() : enabled); }
  bool Excepted(const std::string& host) const {
    auto found=exceptions.find(host);
    return found!=exceptions.end() ? found->second : (inherit_exceptions && original && original->Excepted(host));
  }
  base::WeakPtrFactory<ProfileBlocking> weak{this};
};
ProfileBlocking* State(content::BrowserContext* context) {
  auto* state = static_cast<ProfileBlocking*>(context->GetUserData(&kProfileKey));
  if (!state) {
    auto owned=std::make_unique<ProfileBlocking>(); state=owned.get();
    auto* profile=Profile::FromBrowserContext(context);
    if (profile->IsOffTheRecord()) {
      // Separate mutable policy, shared immutable lists. Never write private
      // exceptions into the original BrowserContext or its preferences.
      auto* original=State(profile->GetOriginalProfile());
      state->original=original->weak.GetWeakPtr();
    }
    context->SetUserData(&kProfileKey,std::move(owned));
  }
  return state;
}
class PageBlocking final : public base::SupportsUserData::Data,
                           public content::WebContentsObserver {
 public:
  explicit PageBlocking(content::WebContents* contents): WebContentsObserver(contents) {}
  uint64_t count=0;
  // A factory for a reused RFH can be created before DidCommit resets that
  // RFH's WeakDocumentPtr. Tag it with the pending navigation instead of
  // rebinding a stale document to whichever page later occupies the frame.
  std::map<content::GlobalRenderFrameHostId,int64_t> pending, committed;
  std::map<int64_t,uint64_t> early_counts;
  void ReadyToCommitNavigation(content::NavigationHandle* handle) override {
    if (!handle->IsSameDocument() && !handle->IsPageActivation())
      pending[handle->GetRenderFrameHost()->GetGlobalId()]=handle->GetNavigationId();
  }
  int64_t Expected(content::RenderFrameHost* frame) const {
    auto id=frame->GetGlobalId();
    if (auto found=pending.find(id); found!=pending.end()) return found->second;
    if (auto found=committed.find(id); found!=committed.end()) return found->second;
    return 0;
  }
  void Blocked(content::RenderFrameHost* frame,int64_t expected,bool live_document) {
    auto id=frame->GetGlobalId();
    if (expected && pending.contains(id) && pending.at(id)==expected) {
      early_counts[expected]++; return;
    }
    const bool current=expected ? (committed.contains(id) && committed.at(id)==expected) : live_document;
    if (current && frame->IsActive()) count++;
  }
  void DidFinishNavigation(content::NavigationHandle* handle) override {
    if (handle->IsSameDocument()) return;
    auto navigation=handle->GetNavigationId();
    if (handle->HasCommitted()) {
      auto* frame=handle->GetRenderFrameHost();
      // Activation reuses the document and its existing factories. Preserve
      // their navigation identity while starting this tab's displayed count.
      if (!handle->IsPageActivation()) committed[frame->GetGlobalId()]=navigation;
      if (handle->IsInPrimaryMainFrame()) count=0;
      if (frame->IsActive()) {
        if (auto found=early_counts.find(navigation); found!=early_counts.end()) count+=found->second;
      }
    }
    early_counts.erase(navigation);
    std::erase_if(pending,[navigation](const auto& entry) { return entry.second==navigation; });
  }
  void RenderFrameDeleted(content::RenderFrameHost* frame) override {
    auto id=frame->GetGlobalId();
    if (auto found=pending.find(id); found!=pending.end()) early_counts.erase(found->second);
    pending.erase(id); committed.erase(id);
  }
  static PageBlocking* Get(content::WebContents* contents) {
    auto* result=static_cast<PageBlocking*>(contents->GetUserData(&kPageKey));
    if (!result) {
      auto owned=std::make_unique<PageBlocking>(contents); result=owned.get();
      contents->SetUserData(&kPageKey,std::move(owned));
    }
    return result;
  }
};
std::string RequestType(const network::ResourceRequest& request) {
  using D=network::mojom::RequestDestination;
  switch(request.destination) {
    case D::kDocument: return "document";
    case D::kFrame: case D::kIframe: case D::kFencedframe: return "subdocument";
    case D::kImage: return "image";
    case D::kStyle: return "stylesheet";
    case D::kScript: case D::kWorker: case D::kSharedWorker: case D::kServiceWorker:
    case D::kAudioWorklet: case D::kPaintWorklet: return "script";
    case D::kFont: return "font";
    case D::kAudio: case D::kVideo: case D::kTrack: return "media";
    case D::kObject: case D::kEmbed: return "object";
    case D::kReport: return "csp_report";
    case D::kEmpty:
      if (request.resource_type==static_cast<int>(blink::mojom::ResourceType::kPing)) return "ping";
      return request.is_fetch_like_api || request.resource_type==static_cast<int>(blink::mojom::ResourceType::kXhr)
          ? "xmlhttprequest" : "other";
    default: return "other";
  }
}
std::string Take(AircBlockingBytes value) {
  std::string result;
  if (value.data) result.assign(reinterpret_cast<const char*>(value.data),value.len);
  airc_blocking_bytes_free(value); return result;
}
struct Decision {
  bool blocked=false;
  GURL rewrite;
  std::string csp;
};
struct MatchContext {
  base::WeakPtr<ProfileBlocking> state;
  content::WeakDocumentPtr document;
  content::GlobalRenderFrameHostId frame_id;
  int64_t expected_navigation=0;
  GURL top_url;
  GURL initiator;
  Decision Evaluate(const network::ResourceRequest& request, bool count, const char* override_type=nullptr) const {
    if (!state || !state->Enabled() || !state->ActiveRules() ||
        !(request.url.SchemeIsHTTPOrHTTPS() || request.url.SchemeIsWSOrWSS())) return {};
    auto* live_document=document.AsRenderFrameHostIfValid();
    auto* frame=content::RenderFrameHost::FromID(frame_id);
    // This bit describes the requesting frame, including its subresources.
    // Only a document navigation supplies a new top-level site. Scripts and
    // fetches in the main frame must retain the page's site-exception context.
    const bool top_navigation=request.is_outermost_main_frame &&
        request.destination==network::mojom::RequestDestination::kDocument;
    GURL top=top_navigation ? request.url : top_url;
    if (top.is_empty() && live_document) top=live_document->GetMainFrame()->GetLastCommittedURL();
    const auto host=Host(top);
    if (!host.empty() && state->Excepted(host)) return {};
    auto source=request.request_initiator && !request.request_initiator->opaque()
      ? request.request_initiator->GetURL() : initiator;
    std::string u=request.url.spec(), s=source.spec(), type=override_type ? override_type : RequestType(request);
    auto raw=airc_blocking_match(state->ActiveRules().get(),Bytes(u),u.size(),Bytes(s),s.size(),
        Bytes(type),type.size(),Bytes(request.method),request.method.size());
    Decision result;
    result.blocked=raw.valid && raw.blocked;
    GURL candidate(Take(raw.rewritten_url));
    // removeparam may alter only a query; never let list data redirect origins,
    // paths, credentials, schemes or fragments through this trusted hook.
    GURL::Replacements no_query; no_query.ClearQuery();
    if (candidate.is_valid() && candidate!=request.url &&
        candidate.ReplaceComponents(no_query)==request.url.ReplaceComponents(no_query)) result.rewrite=candidate;
    result.csp=Take(raw.csp);
    // A dead document can still have keepalive traffic, but it must never
    // increment a replacement document's counter.
    if (result.blocked && count && frame) {
      if (auto* contents=content::WebContents::FromRenderFrameHost(frame))
        PageBlocking::Get(contents)->Blocked(frame,expected_navigation,live_document!=nullptr);
    }
    return result;
  }
};
// Owns exactly one load. Each disconnect and completion tears down all endpoints;
// no callback retains a raw Profile, WebContents or factory pointer.
class BlockingLoad final : public network::mojom::URLLoader,
                           public network::mojom::URLLoaderClient {
 public:
  BlockingLoad(MatchContext context, Decision decision, network::mojom::URLLoaderFactory* factory,
      mojo::PendingReceiver<network::mojom::URLLoader> receiver, int32_t id, uint32_t options,
      const network::ResourceRequest& request, mojo::PendingRemote<network::mojom::URLLoaderClient> client,
      const net::MutableNetworkTrafficAnnotationTag& annotation)
      : context_(std::move(context)), decision_(std::move(decision)), request_(request), receiver_(this,std::move(receiver)),
        client_(std::move(client)), response_(this) {
    receiver_.set_disconnect_handler(base::BindOnce(&BlockingLoad::End,base::Unretained(this)));
    client_.set_disconnect_handler(base::BindOnce(&BlockingLoad::End,base::Unretained(this)));
    if (decision_.rewrite.is_valid()) request_.url=decision_.rewrite;
    factory->CreateLoaderAndStart(loader_.BindNewPipeAndPassReceiver(),id,options,request_,
        response_.BindNewPipeAndPassRemote(),annotation);
    response_.set_disconnect_handler(base::BindOnce(&BlockingLoad::Disconnected,base::Unretained(this)));
  }
  void FollowRedirect(network::HttpRequestHeadersUpdateParams headers, const std::optional<GURL>& url) override {
    if (url) request_.url=*url;
    decision_=context_.Evaluate(request_,true);
    if (decision_.blocked) { Complete(net::ERR_BLOCKED_BY_CLIENT); return; }
    if (decision_.rewrite.is_valid()) request_.url=decision_.rewrite;
    // Supply the checked target even when a filter removed parameters from a
    // server redirect. The downstream network loader retains redirect checks.
    loader_->FollowRedirect(std::move(headers),request_.url);
  }
  void SetPriority(net::RequestPriority priority,int32_t intra) override { loader_->SetPriority(priority,intra); }
  void OnReceiveEarlyHints(network::mojom::EarlyHintsPtr hints) override { client_->OnReceiveEarlyHints(std::move(hints)); }
  void OnReceiveResponse(network::mojom::URLResponseHeadPtr head,mojo::ScopedDataPipeConsumerHandle body,
      std::optional<mojo_base::BigBuffer> metadata) override {
    // Add a separate enforcing policy; never overwrite a site's existing CSP.
    if (!decision_.csp.empty() && decision_.csp.find_first_of("\r\n")==std::string::npos && head->headers) {
      auto policies=network::ParseContentSecurityPolicies(decision_.csp,
          network::mojom::ContentSecurityPolicyType::kEnforce,
          network::mojom::ContentSecurityPolicySource::kHTTP,request_.url);
      if (!head->parsed_headers) head->parsed_headers=network::mojom::ParsedHeaders::New();
      for (auto& policy:policies) head->parsed_headers->content_security_policy.push_back(std::move(policy));
      head->headers->AddHeader("Content-Security-Policy",decision_.csp);
    }
    client_->OnReceiveResponse(std::move(head),std::move(body),std::move(metadata));
  }
  void OnReceiveRedirect(const net::RedirectInfo& redirect,network::mojom::URLResponseHeadPtr head) override {
    request_.url=redirect.new_url; request_.method=redirect.new_method;
    decision_=context_.Evaluate(request_,true);
    if (decision_.blocked) { Complete(net::ERR_BLOCKED_BY_CLIENT); return; }
    auto checked=redirect;
    if (decision_.rewrite.is_valid()) request_.url=checked.new_url=decision_.rewrite;
    client_->OnReceiveRedirect(checked,std::move(head));
  }
  void OnUploadProgress(int64_t current,int64_t total,OnUploadProgressCallback done) override {
    client_->OnUploadProgress(current,total,std::move(done));
  }
  void OnTransferSizeUpdated(int32_t diff) override { client_->OnTransferSizeUpdated(diff); }
  void OnComplete(const network::URLLoaderCompletionStatus& status) override {
    client_->OnComplete(status); End();
  }
 private:
  void Complete(int error) { client_->OnComplete(network::URLLoaderCompletionStatus(error)); End(); }
  void Disconnected() { Complete(net::ERR_ABORTED); }
  void End() { delete this; }
  MatchContext context_;
  Decision decision_;
  network::ResourceRequest request_;
  mojo::Receiver<network::mojom::URLLoader> receiver_;
  mojo::Remote<network::mojom::URLLoaderClient> client_;
  mojo::Receiver<network::mojom::URLLoaderClient> response_;
  mojo::Remote<network::mojom::URLLoader> loader_;
};
class BlockingFactory final : public network::SelfDeletingURLLoaderFactory {
 public:
  BlockingFactory(mojo::PendingReceiver<network::mojom::URLLoaderFactory> receiver,
      mojo::PendingRemote<network::mojom::URLLoaderFactory> target,MatchContext context,base::SelfDeletingPassKey key)
      : SelfDeletingURLLoaderFactory(std::move(receiver),key), target_(std::move(target)), context_(std::move(context)) {
    target_.set_disconnect_handler(base::BindOnce(&BlockingFactory::Disconnected,base::Unretained(this)));
  }
  void CreateLoaderAndStart(mojo::PendingReceiver<network::mojom::URLLoader> receiver,
      int32_t id,uint32_t options,const network::ResourceRequest& request,
      mojo::PendingRemote<network::mojom::URLLoaderClient> client,
      const net::MutableNetworkTrafficAnnotationTag& annotation) override {
    auto decision=context_.Evaluate(request,true);
    if (decision.blocked) {
      mojo::Remote<network::mojom::URLLoaderClient> remote(std::move(client));
      remote->OnComplete(network::URLLoaderCompletionStatus(net::ERR_BLOCKED_BY_CLIENT)); return;
    }
    new BlockingLoad(context_,std::move(decision),target_.get(),std::move(receiver),id,options,request,std::move(client),annotation);
  }
 private:
  ~BlockingFactory() override = default;
  void Disconnected() { DisconnectReceiversAndDestroy(); }
  mojo::Remote<network::mojom::URLLoaderFactory> target_;
  MatchContext context_;
};
}
void ObserveBlockingPage(content::WebContents* contents) {
  // Observe before the first navigation reaches ReadyToCommitNavigation.
  PageBlocking::Get(contents);
}
void AppendBlockingFactory(content::BrowserContext* context,content::RenderFrameHost* frame,
    content::ContentBrowserClient::URLLoaderFactoryType type,const url::Origin& initiator,
    const net::IsolationInfo& isolation,network::URLLoaderFactoryBuilder& builder) {
  using T=content::ContentBrowserClient::URLLoaderFactoryType;
  if (type==T::kDevTools || type==T::kDownload) return;
  MatchContext match;
  match.state=State(context)->weak.GetWeakPtr(); match.initiator=initiator.GetURL();
  if (frame) {
    match.document=frame->GetWeakDocumentPtr(); match.frame_id=frame->GetGlobalId();
    match.top_url=frame->GetMainFrame()->GetLastCommittedURL();
    if (auto* contents=content::WebContents::FromRenderFrameHost(frame))
      match.expected_navigation=PageBlocking::Get(contents)->Expected(frame);
  }
  if (isolation.top_frame_origin() && !isolation.top_frame_origin()->opaque())
    match.top_url=isolation.top_frame_origin()->GetURL();
  auto [receiver,target]=builder.Append();
  base::MakeSelfDeleting<BlockingFactory>(std::move(receiver),std::move(target),std::move(match));
}
bool BlockWebSocket(content::RenderFrameHost* frame,const GURL& url) {
  if (!frame) return false;
  MatchContext match;
  match.state=State(frame->GetBrowserContext())->weak.GetWeakPtr();
  match.document=frame->GetWeakDocumentPtr(); match.frame_id=frame->GetGlobalId();
  if (auto* contents=content::WebContents::FromRenderFrameHost(frame))
    match.expected_navigation=PageBlocking::Get(contents)->Expected(frame);
  match.top_url=frame->GetMainFrame()->GetLastCommittedURL();
  match.initiator=frame->GetLastCommittedOrigin().GetURL();
  network::ResourceRequest request;
  request.url=url; request.method="GET"; request.request_initiator=frame->GetLastCommittedOrigin();
  return match.Evaluate(request,true,"websocket").blocked;
}
} // namespace airc

@implementation AircEngine (Blocking)
- (void)setBlockingLists:(NSString*)lists enabled:(BOOL)enabled profile:(AircProfile*)profile completion:(void (^)(BOOL))done {
  if (!profile.chromeProfile || [lists lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>32*1024*1024) { done(NO); return; }
  auto* state=airc::State(profile.chromeProfile);
  auto version=++state->generation; auto weak=state->weak.GetWeakPtr();
  static base::NoDestructor<scoped_refptr<base::SequencedTaskRunner>> builder(
      base::ThreadPool::CreateSequencedTaskRunner({base::TaskPriority::USER_VISIBLE}));
  (*builder)->PostTaskAndReplyWithResult(FROM_HERE,
      base::BindOnce([](std::string text) {
        return airc::Compile(std::move(text));
      },base::SysNSStringToUTF8(lists)),
      base::BindOnce([](base::WeakPtr<airc::ProfileBlocking> state,uint64_t version,bool enabled,void (^done)(BOOL),airc::Rules rules) {
        if (!state || state->generation!=version || !rules) { done(NO); return; }
        state->rules=std::move(rules); state->enabled_override=enabled;
        // Once the app installs this context's policy, it supplies the complete
        // resolved exception set. Inheriting again would override an explicit
        // private "on" choice when the ordinary profile later adds a bypass.
        state->inherit_exceptions=false;
        done(YES);
      },weak,version,static_cast<bool>(enabled),[done copy]));
}
- (void)setBlockingEnabled:(BOOL)enabled profile:(AircProfile*)profile {
  if (profile.chromeProfile) {
    auto* state=airc::State(profile.chromeProfile);
    ++state->generation; state->enabled_override=enabled;
  }
}
- (BOOL)setBlockingException:(BOOL)excepted site:(NSString*)site profile:(AircProfile*)profile {
  if (!profile.chromeProfile) return NO;
  auto host=airc::Host(GURL(base::SysNSStringToUTF8(site))); if (host.empty()) return NO;
  auto* state=airc::State(profile.chromeProfile);
  state->exceptions[host]=excepted;
  return YES;
}
- (NSDictionary*)blockingCosmeticsForURL:(NSString*)url profile:(AircProfile*)profile {
  if (!profile.chromeProfile) return @{};
  auto* state=airc::State(profile.chromeProfile); auto value=base::SysNSStringToUTF8(url);
  if (!state->Enabled() || !state->ActiveRules() || state->Excepted(airc::Host(GURL(value)))) return @{};
  return airc::JSON(airc_blocking_cosmetics(state->ActiveRules().get(),airc::Bytes(value),value.size()));
}
- (NSArray<NSString*>*)blockingGenericCosmeticsForURL:(NSString*)url tokens:(NSString*)tokens profile:(AircProfile*)profile {
  if (!profile.chromeProfile) return @[];
  auto* state=airc::State(profile.chromeProfile); auto value=base::SysNSStringToUTF8(url);
  if (!state->Enabled() || !state->ActiveRules() || state->Excepted(airc::Host(GURL(value)))) return @[];
  auto input=base::SysNSStringToUTF8(tokens);
  id result=airc::JSONValue(airc_blocking_generic_cosmetics(state->ActiveRules().get(),airc::Bytes(value),value.size(),
      airc::Bytes(input),input.size()));
  return [result isKindOfClass:NSArray.class] ? result : @[];
}
- (BOOL)setThirdPartyCookiesBlocked:(BOOL)blocked profile:(AircProfile*)profile {
  if (!profile.chromeProfile) return NO;
  auto* preferences=profile.chromeProfile->GetPrefs();
  if (preferences->IsManagedPreference(prefs::kCookieControlsMode)) return NO;
  preferences->SetInteger(prefs::kCookieControlsMode,static_cast<int>(blocked
      ? content_settings::CookieControlsMode::kBlockThirdParty : content_settings::CookieControlsMode::kOff));
  return YES;
}
- (BOOL)disableBlockingExtension:(NSString*)extensionID profile:(AircProfile*)profile {
  if (!profile.chromeProfile || profile.chromeProfile->IsOffTheRecord()) return NO;
  auto* context=profile.chromeProfile; auto id=base::SysNSStringToUTF8(extensionID);
  auto* registry=extensions::ExtensionRegistry::Get(context);
  auto* extension=registry->enabled_extensions().GetByID(id);
  auto* system=extensions::ExtensionSystem::Get(context);
  if (!extension || !system || !system->management_policy()->UserMayModifySettings(extension,nullptr) ||
      system->management_policy()->MustRemainEnabled(extension,nullptr)) return NO;
  extensions::ExtensionRegistrar::Get(context)->DisableExtension(id,{extensions::disable_reason::DISABLE_USER_ACTION});
  return !registry->enabled_extensions().Contains(id);
}
@end
@implementation AircTab (Blocking)
- (NSUInteger)blockedRequestCount {
  return self.contents ? airc::PageBlocking::Get(self.contents)->count : 0;
}
@end

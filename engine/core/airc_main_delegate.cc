#include "airc/core/airc_blocking.h"
#include "services/network/public/mojom/websocket.mojom.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "net/base/net_errors.h"
// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#include "airc/core/airc_main_delegate.h"
#include "airc/core/airc_service_policy.h"

#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <variant>
#include <vector>

#include "base/base_switches.h"
#include "base/command_line.h"
#include "base/environment.h"
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/logging.h"
#include "base/no_destructor.h"
#include "base/path_service.h"
#include "base/run_loop.h"
#include "base/strings/string_split.h"
#include "base/strings/string_util.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/browser_process_impl.h"
#include "chrome/browser/chrome_browser_main.h"
#include "chrome/browser/chrome_browser_main_extra_parts.h"
#include "chrome/browser/chrome_content_browser_client.h"
#include "chrome/common/chrome_paths.h"
#include "chrome/common/chrome_paths_internal.h"
#include "chrome/common/chrome_switches.h"
#include "chrome/common/profiler/main_thread_stack_sampling_profiler.h"
#include "components/component_updater/component_updater_paths.h"
#include "airc/core/airc_drm_policy.h"
#include "components/keep_alive_registry/keep_alive_types.h"
#include "components/keep_alive_registry/scoped_keep_alive.h"
#include "components/os_crypt/common/os_crypt_switches.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/browser_url_handler.h"
#include "content/public/browser/browser_main_parts.h"
#include "content/public/common/content_switches.h"
#include "extensions/common/switches.h"
#include "third_party/blink/public/common/switches.h"
#include "content/public/common/result_codes.h"
#include "services/cert_verifier/public/mojom/cert_verifier_service_factory.mojom.h"
#include "services/network/public/mojom/network_context.mojom.h"
#include "airc/core/airc_content_hooks.h"
#include "airc/core/airc_hooks.h"
#include "airc/core/airc_launch_switches.h"
#include "airc/core/airc_lifetime.h"
#include "airc/core/airc_context_menu.h"
#include "airc/core/airc_navigation_hold.h"
#include "airc/core/airc_app_urls.h"
#include "airc/core/airc_page_channel.h"
#include "airc/core/airc_page_script.h"
#include "airc/core/airc_safe_storage.h"
#include "airc/core/airc_seams.h"
#include "airc/core/airc_strings.h"
#include "content/public/browser/web_contents_view_delegate.h"
#include "airc/core/renderer/airc_content_renderer_client.h"
#include "third_party/blink/public/common/associated_interfaces/associated_interface_registry.h"

namespace airc {

namespace {

bool g_browser_started = false;

constexpr char kBundledContentBlockerId[] = "fajbdaomknpkicfjcpipdmcpoamdmilh";

bool IsBundledComponentExtension(const extensions::ExtensionId& extension_id) {
  return extension_id == kBundledContentBlockerId;
}

constexpr const char* kSwitchesThatOpenTheProfile[] = {
    "allow-insecure-localhost",
    "auto-open-devtools-for-tabs",
    "custom-devtools-frontend",
    "devtools-flags",
    "disable-extensions-except",
    "disable-web-security",
    "enable-automation",
    "enable-ui-devtools",
    "extensions-on-chrome-urls",
    "extensions-on-extension-urls",
    "host-resolver-rules",
    "host-rules",
    "ignore-certificate-errors",
    "ignore-certificate-errors-spki-list",
    "load-apps",
    "load-extension",
    "log-net-log",
    "net-log-capture-mode",
    "proxy-pac-url",
    "proxy-server",
    "remote-allow-origins",
    "remote-debugging-address",
    "remote-debugging-io-pipes",
    "remote-debugging-pipe",
    "remote-debugging-port",
    "remote-debugging-socket-name",
    "remote-debugging-targets",
    "silent-debugger-extension-api",
    "ssl-key-log-file",
    "unsafely-treat-insecure-origin-as-secure",
    "webtransport-developer-mode",
};

constexpr const char* kEnvironmentThatOpensTheProfile[] = {
    "SSLKEYLOGFILE",
};

void RemoveSwitchesThatOpenTheProfile(base::CommandLine* command_line) {
  for (const char* name : kSwitchesThatOpenTheProfile) {
    command_line->RemoveSwitch(name);
  }
}

std::string EnvironmentThatOpensTheProfile(base::Environment& env) {
  std::string set;
  for (const char* name : kEnvironmentThatOpensTheProfile) {
    if (env.HasVar(std::string(name))) {
      set += std::string(set.empty() ? "" : " ") + name;
    }
  }
  return set.empty() ? "none" : set;
}

void KeepRealProfileClosed(base::CommandLine* command_line,
                           std::string_view stage) {
  const bool mock_keychain =
      command_line->HasSwitch(os_crypt::switches::kUseMockKeychain) &&
      !TestFlag("applyProfileGate");
  std::unique_ptr<base::Environment> env = base::Environment::Create();
  if (Traced("profileGate")) {
    base::CommandLine closed(*command_line);
    RemoveSwitchesThatOpenTheProfile(&closed);
    LOG(ERROR) << "[airc] profile gate " << stage << " (applies here: "
               << (mock_keychain ? "no" : "yes") << ")\n  parsed: "
               << command_line->GetCommandLineString()
               << "\n  closed: " << closed.GetCommandLineString()
               << "\n  environment it unsets: "
               << EnvironmentThatOpensTheProfile(*env);
  }
  if (!mock_keychain) {
    RemoveSwitchesThatOpenTheProfile(command_line);
    for (const char* name : kEnvironmentThatOpensTheProfile) {
      env->UnSetVar(std::string(name));
    }
  }
}

std::unique_ptr<ScopedKeepAlive>& AppKeepAlive() {
  static base::NoDestructor<std::unique_ptr<ScopedKeepAlive>> keep_alive;
  return *keep_alive;
}

class AircBrowserMainExtraParts : public ChromeBrowserMainExtraParts {
 public:
  void PreBrowserStart() override {
    AppKeepAlive() = std::make_unique<ScopedKeepAlive>(
        KeepAliveOrigin::APP_CONTROLLER, KeepAliveRestartOption::DISABLED);
    StartLifetimeObservers();
  }
  void PostBrowserStart() override {
    g_browser_started = true;
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&OnEngineStarted));
  }
  void PostMainMessageLoopRun() override {
    OnEngineShuttingDown();
  }
};

class AircBrowserMainParts : public content::BrowserMainParts {
 public:
  explicit AircBrowserMainParts(std::unique_ptr<content::BrowserMainParts> chrome)
      : chrome_(std::move(chrome)) {}

  int PreEarlyInitialization() override {
    return chrome_->PreEarlyInitialization();
  }
  void PostEarlyInitialization() override {
    chrome_->PostEarlyInitialization();
  }
  void ToolkitInitialized() override { chrome_->ToolkitInitialized(); }
  void PreCreateMainMessageLoop() override {
    chrome_->PreCreateMainMessageLoop();
  }
  void PostCreateMainMessageLoop() override {
    chrome_->PostCreateMainMessageLoop();
  }
  int PreCreateThreads() override { return chrome_->PreCreateThreads(); }
  int PostCreateThreads() override { return chrome_->PostCreateThreads(); }
  int PreMainMessageLoopRun() override {
    result_ = chrome_->PreMainMessageLoopRun();
    return result_;
  }
  bool ShouldInterceptMainMessageLoopRun() override {
    return result_ == content::RESULT_CODE_NORMAL_EXIT && g_browser_started;
  }
  void WillRunMainMessageLoop(std::unique_ptr<base::RunLoop>& run_loop) override {
    chrome_->WillRunMainMessageLoop(run_loop);
    if (!run_loop) {
      run_loop = std::make_unique<base::RunLoop>();
      static_cast<BrowserProcessImpl*>(g_browser_process)
          ->SetQuitClosure(run_loop->QuitWhenIdleClosure());
    }
  }
  void OnFirstIdle() override { chrome_->OnFirstIdle(); }
  void PostMainMessageLoopRun() override { chrome_->PostMainMessageLoopRun(); }
  void PostDestroyThreads() override { chrome_->PostDestroyThreads(); }

 private:
  std::unique_ptr<content::BrowserMainParts> chrome_;
  int result_ = content::RESULT_CODE_NORMAL_EXIT;
};

// Interpose registration, not URL processing. Chrome still installs all policy,
// extension and new-tab handlers; only its WebUI rewrite belongs to the host.
// No testing setters, symbol interposition or upstream source copy is needed.
class HostURLHandlerRegistration final : public content::BrowserURLHandler {
 public:
  HostURLHandlerRegistration(content::BrowserURLHandler* target, URLHandler omit)
      : target_(target), omit_(omit) {}
  void RewriteURLIfNecessary(GURL* url, content::BrowserContext* context) override {
    target_->RewriteURLIfNecessary(url, context);
  }
  std::vector<GURL> GetPossibleRewrites(
      const GURL& url, content::BrowserContext* context) override {
    return target_->GetPossibleRewrites(url, context);
  }
  void AddHandlerPair(URLHandler forward, URLHandler reverse) override {
    if (forward != omit_) target_->AddHandlerPair(forward, reverse);
  }
  void RemoveHandlerForTesting(URLHandler handler) override {
    target_->RemoveHandlerForTesting(handler);
  }
 private:
  raw_ptr<content::BrowserURLHandler> target_;
  URLHandler omit_;
};

class AircContentBrowserClient : public ChromeContentBrowserClient {
 public:
  void OnWebContentsCreated(content::WebContents* contents) override {
    ChromeContentBrowserClient::OnWebContentsCreated(contents);
    ObserveBlockingPage(contents);
  }
  void WillCreateURLLoaderFactory(content::BrowserContext* context,
      content::RenderFrameHost* frame, int process_id, URLLoaderFactoryType type,
      const url::Origin& initiator, const net::IsolationInfo& isolation,
      std::optional<int64_t> navigation_id, ukm::SourceIdObj source_id,
      network::URLLoaderFactoryBuilder& builder,
      mojo::PendingRemote<network::mojom::TrustedURLLoaderHeaderClient>* headers,
      bool* bypass_redirect_checks, bool* disable_secure_dns,
      network::mojom::URLLoaderFactoryOverridePtr* factory_override,
      scoped_refptr<base::SequencedTaskRunner> navigation_runner,
      bool for_network_service) override {
    ChromeContentBrowserClient::WillCreateURLLoaderFactory(context,frame,process_id,
        type,initiator,isolation,navigation_id,source_id,builder,headers,
        bypass_redirect_checks,disable_secure_dns,factory_override,
        std::move(navigation_runner),for_network_service);
    AppendBlockingFactory(context,frame,type,initiator,isolation,builder);
  }
  bool WillInterceptWebSocket(content::RenderFrameHost* frame) override {
    return frame || ChromeContentBrowserClient::WillInterceptWebSocket(frame);
  }
  void CreateWebSocket(content::RenderFrameHost* frame, WebSocketFactory factory,
      const GURL& url, const net::SiteForCookies& cookies,
      const std::optional<std::string>& user_agent,
      mojo::PendingRemote<network::mojom::WebSocketHandshakeClient> client,
      WebSocketOptions options) override {
    if (BlockWebSocket(frame,url)) {
      mojo::Remote<network::mojom::WebSocketHandshakeClient> remote(std::move(client));
      remote->OnFailure("Blocked by Airc",net::ERR_BLOCKED_BY_CLIENT,-1);
      return;
    }
    ChromeContentBrowserClient::CreateWebSocket(frame,std::move(factory),url,cookies,
        user_agent,std::move(client),std::move(options));
  }
  void BrowserURLHandlerCreated(content::BrowserURLHandler* handler) override {
    HostURLHandlerRegistration registration(handler, &HandleWebUI);
    ChromeContentBrowserClient::BrowserURLHandlerCreated(&registration);
  }
  void RenderProcessWillLaunch(content::RenderProcessHost* host) override {
    ChromeContentBrowserClient::RenderProcessWillLaunch(host);
    SendPageScript(host);
  }
  void RegisterAssociatedInterfaceBindersForRenderFrameHost(
      content::RenderFrameHost& render_frame_host,
      blink::AssociatedInterfaceRegistry& associated_registry) override {
    ChromeContentBrowserClient::
        RegisterAssociatedInterfaceBindersForRenderFrameHost(
            render_frame_host, associated_registry);
    RegisterPageChannelBinders(render_frame_host, associated_registry);
  }
  std::unique_ptr<content::WebContentsViewDelegate> GetWebContentsViewDelegate(
      content::WebContents* web_contents) override {
    return CreateViewDelegate(web_contents);
  }
  void CreateThrottlesForNavigation(
      content::NavigationThrottleRegistry& registry) override {
    ChromeContentBrowserClient::CreateThrottlesForNavigation(registry);
    AddAppSchemeThrottle(registry);
    MaybeAddNavigationHoldThrottle(registry);
  }
  void AppendExtraCommandLineSwitches(base::CommandLine* command_line,
                                      int child_process_id) override {
    ChromeContentBrowserClient::AppendExtraCommandLineSwitches(command_line,
                                                               child_process_id);
    PassSwitchesToGpuProcess(command_line);
  }
  std::optional<base::TimeDelta> GetSpareRendererDelayForSiteURL(
      const GURL& site_url) override {
    std::optional<base::TimeDelta> delay =
        ChromeContentBrowserClient::GetSpareRendererDelayForSiteURL(site_url);
    return delay ? delay : std::optional<base::TimeDelta>(base::Milliseconds(500));
  }

  void ConfigureNetworkContextParams(
      content::BrowserContext* context,
      bool in_memory,
      const base::FilePath& relative_partition_path,
      network::mojom::NetworkContextParams* network_context_params,
      cert_verifier::mojom::CertVerifierCreationParams*
          cert_verifier_creation_params) override {
    ChromeContentBrowserClient::ConfigureNetworkContextParams(
        context, in_memory, relative_partition_path, network_context_params,
        cert_verifier_creation_params);
    if (!in_memory && relative_partition_path.empty() &&
        !context->IsOffTheRecord()) {
      network_context_params->restore_old_session_cookies = true;
      network_context_params->persist_session_cookies = true;
    }
  }

  std::unique_ptr<content::BrowserMainParts> CreateBrowserMainParts(
      bool is_integration_test) override {
    std::unique_ptr<content::BrowserMainParts> chrome =
        ChromeContentBrowserClient::CreateBrowserMainParts(is_integration_test);
    static_cast<ChromeBrowserMainParts*>(chrome.get())
        ->AddParts(std::make_unique<AircBrowserMainExtraParts>());
    return std::make_unique<AircBrowserMainParts>(std::move(chrome));
  }
};

}

void ReleaseAppKeepAlive() {
  AppKeepAlive().reset();
}

AircMainDelegate::AircMainDelegate(const StartupTimestamps& timestamps)
    : ChromeMainDelegate(timestamps) {
  g_airc_embedder = true;
  g_airc_protected_content_enabled = &ProtectedContentEnabled;
  g_airc_restricted_component_extension = &IsBundledComponentExtension;
  g_airc_resource_bundle_delegate = ProductStrings();
}

AircMainDelegate::~AircMainDelegate() = default;

namespace {

void KeepMemoryReducer(base::CommandLine* command_line) {
  const std::string flags = command_line->GetSwitchValueASCII(blink::switches::kJavaScriptFlags);
  std::vector<std::string> kept;
  bool dropped = false;
  for (const std::string& flag :
       base::SplitString(flags, " ,", base::TRIM_WHITESPACE, base::SPLIT_WANT_NONEMPTY)) {
    if (flag == "--no-memory-reducer" || flag == "--no_memory_reducer") {
      dropped = true;
    } else {
      kept.push_back(flag);
    }
  }
  if (!dropped) {
    return;
  }
  command_line->RemoveSwitch(blink::switches::kJavaScriptFlags);
  if (!kept.empty()) {
    command_line->AppendSwitchASCII(blink::switches::kJavaScriptFlags, base::JoinString(kept, " "));
  }
}

void MergeFeatures(base::CommandLine* command_line, const char* list, std::string_view features) {
  const std::string current = command_line->GetSwitchValueASCII(list);
  command_line->RemoveSwitch(list);
  command_line->AppendSwitchASCII(list, current.empty() ? std::string(features)
                                                        : current + "," + std::string(features));
}

// Startup-only kill switches, engine-owned. Off restores the pre-pass defaults;
// no persisted user prefs are rewritten. See engine/BACKGROUND-SERVICES.md.
void ConfigureBackgroundServices(base::CommandLine* command_line) {
  // No Safe Browsing service in this build. Command-line prefs cover all profiles
  // before services start, without reporting enterprise/browser management.
  command_line->AppendSwitch("airc-disable-safe-browsing");
  // Actor's navigation list is not Safe Browsing/CRLSet. Omit it only while
  // Glic/AI actions are disabled; restore before exposing any actor surface.
  g_airc_skip_actor_safety_lists = SwitchOn("quietModels") && SwitchOn("quietActorLists");
  if (SwitchOn("quietModels")) {
    // Airc has no Google AI UI. In M156 OptimizationHints also gates the
    // shared model-delivery holder. The separate manifest broker must also
    // be disabled; keep its unavailable capability stub for existing consumers.
    MergeFeatures(command_line, switches::kDisableFeatures,
        "OptimizationHints,OptimizationTargetPrediction,"
        "OptimizationGuideModelExecution,OptimizationGuideManifestBroker,"
        "OnDeviceModelBackgroundDownload,"
        "LogOnDeviceMetricsOnStartup,OnDeviceModelFetchPerformanceClassEveryStartup,"
        "Glic,GlicWarming");
  }
  if (SwitchOn("quietHistory")) {
    // Keep ordinary history/search, omit model-backed grouping and enrichment.
    MergeFeatures(command_line, switches::kDisableFeatures,
        "Journeys,HistoryEmbeddings,HistoryEmbeddingsAnswers,"
        "OnDeviceCategoryClassifier,AnnotatedPageContentExtraction");
  }
  if (SwitchOn("quietCommerce")) {
    // No Google shopping/price-tracking surface in Airc; bookmarks remain local.
    MergeFeatures(command_line, switches::kDisableFeatures,
        "ShoppingList,ShoppingPageTypes,ShoppingPDPMetrics,"
        "PriceInsights,PriceAnnotations,DiscountAutofill,RetailCoupons");
  }
  if (SwitchOn("quietTranslateDownloads")) {
    // Stop speculative language-pack downloads, not user-requested translation
    // or macOS's local spellchecker. Preserve the shared component updater.
    MergeFeatures(command_line, switches::kDisableFeatures,
        "AutoDownloadTranslateLanguagePacks");
  }
  if (SwitchOn("quietTelemetry")) {
    // Unbranded builds already deny metrics consent/upload. Stop the local
    // segmentation UKM database and AI quality logging too. Keep the Ukm
    // service object: M156 unconditionally constructs an observer of it, even
    // with segmentation disabled. metrics-recording-only would force recording.
    MergeFeatures(command_line, switches::kDisableFeatures,
        "SegmentationPlatform,SegmentationPlatformUkmEngine,ModelQualityLogging");
  }
  if (SwitchOn("quietLockMetrics"))
    MergeFeatures(command_line, switches::kDisableFeatures, "RecordLockAcquisitionTime");
  if (SwitchOn("quietVariations")) {
    // Unbranded builds otherwise enroll in the field-trial TESTING config.
    // Keep feature defaults reproducible. Seed fetch is already off in this
    // unbranded build; the second switch also covers future branded builds.
    command_line->AppendSwitch("disable-field-trial-config");
    command_line->AppendSwitch("disable-variations-seed-fetch");
  }
  if (SwitchOn("quietSync")) {
    // Airc has no Google browser-sync UI. This does not disable Google web
    // cookies/IdentityManager, local passwords, autofill or extension updates.
    command_line->AppendSwitch("disable-sync");
  }
}

constexpr int kDiskSpaceCheckSeconds = 60;

void QuietIdleTimers(base::CommandLine* command_line) {
  MergeFeatures(command_line, switches::kEnableFeatures, "PartitionAllocAdaptiveMemoryReclaimInterval");
  g_airc_skip_cpu_health_sampling = true;
  g_airc_disk_space_check_seconds = kDiskSpaceCheckSeconds;
  g_airc_lazy_storage_usage = true;
  g_airc_script_loader_ready_at_once = true;
  g_airc_scripts_wait_at_response = true;
  g_airc_bluetooth_poll_on_demand = true;
  g_airc_hybrid_scan_on_demand = true;
}

}

void AircMainDelegate::CreateThreadPool(std::string_view name) {
  // Must precede ChromeMainDelegate::CreateThreadPool: it constructs the
  // profiler BEFORE BasicStartupComplete. Unbranded builds enroll 100%.
  // Airc has no consumer for these periodically collected stack profiles.
  if (SwitchOn("quietProfiling"))
    base::CommandLine::ForCurrentProcess()->AppendSwitch(switches::kDisableStackProfiler);
  ChromeMainDelegate::CreateThreadPool(name);
}

std::optional<int> AircMainDelegate::BasicStartupComplete() {
  base::CommandLine* command_line = base::CommandLine::ForCurrentProcess();
  g_airc_begin_frame_bridge = ExperimentOn("beginFrameBridge");
  if (!command_line->HasSwitch(switches::kProcessType)) {
    g_airc_background_instance = BackgroundInstance();
    DecideTestGateAtStartup();
    KeepRealProfileClosed(command_line, "at startup");
    GuardSafeStorageKey(*command_line);
    command_line->AppendSwitch(switches::kNoStartupWindow);
    command_line->AppendSwitch(switches::kNoFirstRun);
    command_line->AppendSwitch(switches::kNoDefaultBrowserCheck);
    command_line->RemoveSwitch(switches::kMakeDefaultBrowser);
    MergeFeatures(command_line, switches::kEnableFeatures, "WebContentsDiscard");
    g_airc_auto_picture_in_picture_off = !SwitchOn("autoPip");
    MergeFeatures(command_line, SwitchOn("autoPipVideo") && SwitchOn("autoPip")
        ? switches::kEnableFeatures : switches::kDisableFeatures,
        "BrowserInitiatedAutomaticPictureInPicture");
    // Airc supplies activation; the Views occlusion tracker assumes BrowserView.
    MergeFeatures(command_line, switches::kDisableFeatures,
        "AutoPictureInPictureOnWindowOccluded,BrowserInitiatedAutomaticPictureInPictureDryRun");
    if (!SwitchOn("documentPip"))
      MergeFeatures(command_line, switches::kDisableFeatures, "DocumentPictureInPictureAPI");
    // Chromium's supported MV3 migration keeps Hangouts/Meet integration without
    // a persistent extension renderer in every otherwise empty profile.
    MergeFeatures(command_line, switches::kEnableFeatures, "HangoutsExtensionV3");
    // Use upstream's dependency-aware lazy factories. Keep security monitoring eager.
    MergeFeatures(command_line, switches::kEnableFeatures,
        "LazyKeyedServiceInstantiation:LazyKeyedServiceInstantiationSafeBrowsing/false/"
        "LazyKeyedServiceInstantiationSafetyHub/false");
    // MEM-4: helpers that link the framework at launch ("Aperitif") instead of dlopen()ing it. dyld only page-in
    // links launch-time images; a dlopen()ed framework has its pointer fixups written into private pages, 12.9 MB of
    // dirty __DATA_CONST in every renderer, GPU and utility process. Chrome 157 runs these helpers; the framework
    // already builds and embeds them. Off switch: --airc-switches=aperitifHelpers=off.
    if (SwitchOn("aperitifHelpers"))
      MergeFeatures(command_line, switches::kEnableFeatures, "AperitifHelpers");
    QuietIdleTimers(command_line);
    ConfigureBackgroundServices(command_line);
  }
  if (command_line->HasSwitch(extensions::switches::kExtensionProcess)) {
    KeepMemoryReducer(command_line);
  }
  return ChromeMainDelegate::BasicStartupComplete();
}

std::optional<int> AircMainDelegate::PostEarlyInitialization(
    InvokedIn invoked_in) {
  std::optional<int> exit_code =
      ChromeMainDelegate::PostEarlyInitialization(invoked_in);
  if (std::holds_alternative<InvokedInBrowserProcess>(invoked_in)) {
    KeepRealProfileClosed(base::CommandLine::ForCurrentProcess(),
                          "after chrome://flags");
  }
  return exit_code;
}

void AircMainDelegate::PreSandboxStartup() {
  const base::CommandLine& command_line =
      *base::CommandLine::ForCurrentProcess();
  const std::string process_type =
      command_line.GetSwitchValueASCII(switches::kProcessType);
  if (chrome::ProcessNeedsProfileDir(process_type)) {
    base::FilePath dir = command_line.GetSwitchValuePath(switches::kUserDataDir);
    if (dir.empty() && !process_type.empty()) {
      base::FilePath scratch;
      if (base::GetTempDir(&scratch)) {
        base::PathService::OverrideAndCreateIfNeeded(
            chrome::DIR_USER_DATA, scratch.Append("airc-helper"),
            true, false);
      }
      ChromeMainDelegate::PreSandboxStartup();
      return;
    }
    CHECK(!dir.empty()) << "Airc needs --user-data-dir";
    CHECK(base::CreateDirectory(dir));
    dir = base::MakeAbsoluteFilePath(dir);
    CHECK(base::PathService::OverrideAndCreateIfNeeded(
        chrome::DIR_USER_DATA, dir, true, false));
    base::PathService::Override(chrome::DIR_CRASH_DUMPS,
                                dir.Append(FILE_PATH_LITERAL("Crashpad")));
    component_updater::RegisterPathProvider(chrome::DIR_COMPONENTS,
                                            chrome::DIR_USER_DATA);
  }
  if (process_type.empty()) {
    // Ordinary launches skip the early explicit-test decision. Warm their cache
    // after creating the data directory, while startup still permits blocking,
    // before a UI-thread API (e.g. memory-pressure testing) can query it. An
    // early refusal remains final even if the directory has since been created.
    InitializeTestGateAtStartup();
    InstallAppOverrides();
    InstallChromeHooks();
  }
  ChromeMainDelegate::PreSandboxStartup();
}

content::ContentRendererClient* AircMainDelegate::CreateContentRendererClient() {
  static base::NoDestructor<AircContentRendererClient> client;
  return client.get();
}

content::ContentBrowserClient* AircMainDelegate::CreateContentBrowserClient() {
  chrome_content_browser_client_ = std::make_unique<AircContentBrowserClient>();
  if (sampling_profiler_) {
    chrome_content_browser_client_->SetSamplingProfiler(
        std::move(sampling_profiler_));
  }
  return chrome_content_browser_client_.get();
}

}

# Background service policy (Chromium 156)

The original pass-6/7 changes are in `airc_main_delegate.cc`. The later DRM
policy also uses patch 027; it gates only Widevine update requests. The temporary
Widevine-only registration restriction was reverted in the DRM completion pass. The seven pass-6 groups run before
Chrome constructs FeatureList; pass 7 also gates profiling in CreateThreadPool,
before Chrome constructs its stack profiler.
They append supported feature overrides/switches; they add no upstream patches,
remote configuration fetches, recurring timers or persisted user preferences.
Engine owns these startup-only switches. For example:

```
--airc-switches=quietModels=off,quietVariations=off
```

Each switch defaults on. Off omits that group's overrides, restoring the previous
engine behavior on the next launch. It does not undo explicitly supplied Chrome
flags or restore services disabled by another group. To reproduce the pre-pass-6 configuration, turn **all seven** off and also set
`quietProfiling=off` (added in pass 7). This is a local launch rollback,
not a shipped remote kill-switch service. Revisit at the next Chromium rebase.

| Switch | What it omits | Reason / upstream gate |
|---|---|---|
| `quietModels` | OptimizationHints, OptimizationTargetPrediction, OptimizationGuideModelExecution, OnDeviceModelBackgroundDownload, LogOnDeviceMetricsOnStartup, OnDeviceModelFetchPerformanceClassEveryStartup, Glic, GlicWarming | Airc has no Google AI UI. `OptimizationGuideGlobalStateHolderKeyedServiceFactory::GetForProfile` gates shared model delivery on OptimizationHints in M156. The hints installer uses the same gate. |
| `quietHistory` | Journeys, HistoryEmbeddings, HistoryEmbeddingsAnswers, OnDeviceCategoryClassifier, AnnotatedPageContentExtraction | Keep visit history and ordinary search, omit AI grouping/enrichment and speculative page extraction. |
| `quietCommerce` | ShoppingList, ShoppingPageTypes, ShoppingPDPMetrics, PriceInsights, PriceAnnotations, DiscountAutofill, RetailCoupons | No Google shopping/price-tracking surface; ordinary bookmarks/forms retained. |
| `quietTranslateDownloads` | AutoDownloadTranslateLanguagePacks | Avoid speculative packs. User-requested translation, shared components and local spellcheck remain available. |
| `quietTelemetry` | SegmentationPlatform, SegmentationPlatformUkmEngine, ModelQualityLogging | Stop local segmentation UKM storage and AI-quality logging. Retain the UKM service object; recording/reporting remain subject to unbranded consent gating. Unbranded builds already disallow normal UMA upload (`MetricsServiceAccessor`); histogram recording and BrowserMetrics files are NOT eliminated. |
| `quietVariations` | Adds disable-field-trial-config, disable-variations-seed-fetch | Unbranded Chromium otherwise applies the bundled field-trial **testing** configuration. Remote seed fetching already defaults off without a custom server in this build. The fetch switch matters in branded builds; it is not a complete block against explicit developer overrides or previously cached seeds. |
| `quietProfiling` | Adds disable-stack-profiler before thread-pool creation | Unbranded builds otherwise collect startup and periodic stack profiles at 100% enrollment; Airc has no consumer for those telemetry profiles. See PASS7.md for thread deltas. |
| `quietSync` | Adds disable-sync | No Google browser-sync UI. Keep IdentityManager/web account cookies, local autofill/passwords and extension updates. |

Several listed features already default off. Pinning them off is defensive, not
an assertion that each consumed memory before this change. Disabling field-trial
testing changes more than background services; regression tests and the rollback
are important. Command-line disabled features win over explicit enables; use the
Airc kill switch before trying an upstream enable for that group.

## Deliberately retained / already absent

- **Safe Browsing:** prefs and basic URL/download protection are untouched, as are
  eager Safe Browsing/Safety Hub factories. Optimization Guide supplies the
  client-side phishing image classifier/embedding models in this revision, so
  `quietModels` also stops that model delivery. This is not full Chrome protection.
  The unbranded build supplies no production Google API key. URL-list/update code
  uses `google_apis::GetAPIKey`; no-key live protection needs separate verification.
  Do not advertise protection solely because `safebrowsing.enabled` defaults true.
- **Component updater:** Chromium's existing registrations, server URLs, pings,
  scheduling and download behavior are retained. The brief for the first DRM pass
  mistakenly asked to disable other components; that security regression is
  reverted. Patch 027 now only omits **Widevine** from update requests when Play
  protected content is off. Widevine requires HTTPS for checks/pings/payloads and
  uses Chromium's direct downloader; these exceptions do not affect other IDs.
  No blanket disable-background-networking switch is used.
- **Autofill/passwords:** local stores, save/fill and heuristic field recognition
  remain. Model-backed predictions supplied by Optimization Guide are unavailable
  with `quietModels` on. Existing password/address/card acceptance must pass.
- **Extensions and local spellcheck:** no disabling switches or factory bypasses.
- **Privacy Sandbox/Topics:** all three M1 ad API prefs already register false in
  this pin; old BrowsingTopics/InterestGroupStorage feature names are absent. No
  inert feature override or redundant pref write was added. Related Website Sets
  remains enabled to avoid changing cookie compatibility.
- **Media feeds:** no MediaFeeds gate/implementation found in the pinned media
  source. Media playback, discovery and casting are not disabled by a guessed flag.
- **Signin:** sync is disabled, but no IdentityManager removal. Startup remains
  no-first-run/no-default-browser-check/no-startup-window. This does not prove
  every future Google sign-in promotion is suppressed.
- **Timers:** the inherited 60-second disk-space check and Chromium timers still
  exist. A low CPU measurement is NOT proof of MEM-6's literal no-idle-timers rule.

Renderer caps, spare renderer and site isolation are unchanged. Site-per-process
remains enabled. See PERFORMANCE.md for measurements and qualification limits.

A naive `--disable-features=Ukm` crashed at PreProfileInit: M156 unconditionally
constructs a segmentation observer that dereferences GetUkmService. Disabling
SegmentationPlatformUkmEngine only selects its DummyUkmDataManager, **not** the
observer. Final policy therefore retains Ukm itself, disables that local database,
and relies on the existing unbranded metrics-consent gate for recording/reporting.
The manager calls DisableRecording/DisableReporting when consent is absent.
Explicit developer metrics-force switches can override the normal consent rules.
No unsupported upstream fix or test-only setter is used.

Disable the segmentation service as well as its UKM database: leaving its model
executor active with DummyUkmDataManager hit a CHECK(GetUkmDatabase()) during
startup refresh. The SegmentationPlatform feature selects Chromium's supported
DummySegmentationPlatformService (not a test factory), preserving caller contracts.

`quietVariations` also prevents the pinned testing config from enabling
`PreemptiveSodaDownload` (media's production default is false). Older retained
empty-profile scratch runs held about 25 MiB SODA + 194 MiB speech language packs
+ 218 MiB component CRX cache each, even without pages. These are historical disk
observations, not a claimed measured before/after saving in this pass. SODA stays
available when a user requests speech/captions; disabling the component updater
to suppress speculative downloads would unnecessarily break that behavior.

## Validation limits

Use `engine/perf/qualify.sh` to run isolated restart, local form/password,
autofill, discard, extension and Swift adapter acceptance after a change. Use
`engine/perf/launch.sh` to exercise the all-off rollback and each individual
group-off combination on fresh profiles, keeping each alive past the startup
model-refresh interval. These are background tests, not visible UI qualification.

A 20-second fresh-profile probe of the official Safe Browsing phishing test URL
showed no interstitial in either Airc build **or in isolated Chrome**. It therefore
does not establish whether no-key basic protection works. Leave URL protection
on and qualify update/lookup success plus a positive block before shipping; do
not present this inconclusive result as equivalent protection or a policy regression.

## Pass 8 allocation-driven gates

- `quietActorLists` (on): while `quietModels` is also on and therefore Glic/actions
  are disabled, omit registration/parsing of the AI actor navigation safety-list
  component. This list controls **AI actions**, not ordinary navigation, Safe
  Browsing or TLS. Turning either switch off restores registration. Re-enable it
  before exposing any actor surface. Existing downloaded files are not removed.
  One narrow registration hook is in patch 024; total footprint is now 52 upstream
  paths / 24 strict patches (still above the spec's upstream-file target).
- `quietLockMetrics` (on): disable `RecordLockAcquisitionTime`, a telemetry recorder
  with per-thread buffers. This does not disable locks or synchronization. Off
  restores Chromium's feature default.

Use `--airc-switches=quietActorLists=off,quietLockMetrics=off` to roll back just
pass 8. All-off comparisons now need these two switches as well as the seven
pass-6 groups and `quietProfiling`. At the time of pass 8, no V8, ICU, security service, CRLSet updater,
site isolation or user-visible browser feature was removed to meet MEM-1.
See PASS8.md for allocation stacks, physical-footprint measurements and limits.

## Component registration inventory (Chromium 156, macOS)

Source: `chrome/browser/component_updater/registration.cc` and each installer it
calls. Registration calls can be conditional or no-ops; this inventory is not a
claim that every component downloads on a fresh profile. All pre-027 gates are
retained, including Airc's existing quietModels/quietActorLists gates. Turning
protected content off changes none of them.

| Registration family | macOS scope / existing gate |
|---|---|
| CRLSet; PKI Metadata; SSL Error Assistant; File Type Policies | Existing revocation/certificate/error/download-security components; their installer and Safe Browsing build gates remain. |
| Subresource Filter; Safety Tips; Crowd Deny | Existing navigation/permission data and installer feature gates. |
| Origin Trials; Media Engagement Preload; First Party Sets (Related Website Sets) | Existing web compatibility and media data. |
| Trust Token Key Commitments; Private Verification Tokens; Privacy Sandbox Attestations | Existing token/privacy feature gates. |
| On-device Head Suggest; Optimization Hints; History Search Strings; AI Embeddings | Existing locale/feature/consent gates; quietModels/quietHistory are unchanged. |
| Actor Safety Lists | Still gated by pre-existing patch 024 / quietActorLists + quietModels. |
| Indigo; Commerce Heuristics; Amount Extraction Heuristic Regexes | Existing feature/installer gates; quietCommerce unchanged. |
| Dictation Connector; Zxcvbn Data; IWA Key Distribution | Existing desktop registrations and eligibility gates. |
| Screen AI; TranslateKit and language packs; Wasm TTS Engine | Existing demand/preferences/feature/build gates; quietTranslateDownloads unchanged. |
| CAPTCHA Provider; Platform Runtime; AIM Eligibility | Existing conditional installers. |
| Optimization Guide On DeviceModels Manifest | Registered on demand by `optimization_guide_on_device_model_installer.cc::MaybeRegisterManifestComponent`, outside registration.cc; observed even with the existing quiet feature switches. This metadata registration is retained, not a claim that model execution is enabled. |
| Hyphenation | Only if USE_MINIKIN_HYPHENATION is built. |
| Recovery Improved | Registration call exists on macOS, but installer is Google-Chrome-branded only (absent in unbranded Airc). |
| Widevine CDM | Added by enable_widevine; only this ID is governed by Play protected content. |

Additional demand-driven callers outside registration.cc (including SODA speech
and language packs, TranslateKit and accessibility resources) retain unrestricted
registration and their original update configuration. ChromeOS/Android-only
registrations and Windows-only components are not part of this macOS build.
The completion-pass runtime inventory and update evidence are recorded in
PASS-DRM.md; a registered component with a disabled feature is not proof that
that feature is enabled or that a download was required.

Fresh release-host inventory on 2026-11-06 (18 restored components + Widevine):

| Component | ID |
|---|---|
| WASM TTS Engine | `bjbcblmdcnggnibecjikpoljcgkbgphl` |
| Optimization Guide On DeviceModels Manifest | `ceofaddefefcbblgcgnibnonglccbfja` |
| PKI Metadata | `efniojlnjndmcbiieegkicadnoecjjef` |
| Subresource Filter Rules | `gcmjkmgdlgnkkcocmoeiminaijmmjnii` |
| Crowd Deny | `ggkkehgbnfjpeggfpleeakpidbkibbmn` |
| Certificate Error Assistant | `giekcmmlnklenlaomppkphknjmnnpneh` |
| Related Website Sets | `gonpemdgkjcecdgbnaabipppbmgfggbe` |
| Amount Extraction Heuristic Regexes | `hajigopbbjhghbfimgkfmpenfkclmohk` |
| CRLSet | `hfnkpimlhhgieaddgfemjhofmfblmnib` |
| Safety Tips | `jflookgnkcckhobaglndicnbbgbonegd` |
| File Type Policies | `khaoiebndkojlmppeemjhbpbandiljpe` |
| Trust Token Key Commitments | `kiabhabjdbkjdpjbpigfodbdjmbglcoo` |
| MEI Preload | `laoigpblnllgcgjnjnllmfolckpjlhki` |
| Origin Trials | `llkgjffcdpffmhiakmfcdcblohccpfmo` |
| Privacy Sandbox Attestations | `niikhdgajlphfehepabhhblakbdgeefj` |
| OnDeviceHeadSuggest | `obedbbhbpmojnkanicioggnmelmoomoc` |
| Widevine Content Decryption Module | `oimompecagnajdejgnnjijobebaeigek` |
| Zxcvbn Data Dictionaries | `ojhpjlocmbogdgmfpkhlaaeamibhnphh` |
| Captcha Providers | `pficcddpglkpaaihklmahepgjmefdnom` |

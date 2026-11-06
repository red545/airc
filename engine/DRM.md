# Widevine on macOS — investigation, 2026-11-06

This is a source-based investigation for Chromium **156.0.8078.88**, not a claim
that Airc passes any streaming service. Runtime evidence belongs in PASS-DRM.md
and the implementation report. No GPL implementation was copied.

## Verified: build and installation

The pinned [`widevine.gni`](https://chromium.googlesource.com/chromium/src/+/156.0.8078.88/third_party/widevine/cdm/widevine.gni)
allows unbranded macOS arm64 builds to set `enable_widevine=true`.
`enable_library_cdms=true` enables the out-of-process library CDM infrastructure
(already the desktop Views default). Together these enable the Widevine component.
`bundle_widevine_cdm` defaults false in unbranded Chromium; enabling it requires
supplying Google's proprietary binaries. Airc should leave it false.

The pinned [`installer`](https://chromium.googlesource.com/chromium/src/+/156.0.8078.88/chrome/browser/component_updater/widevine_cdm_component_installer.cc)
registers **oimompecagnajdejgnnjijobebaeigek**, with a fixed public-key SHA-256.
Chromium's component updater verifies the CRX signature and manifest, including
CDM compatibility, and installs under the **user-data root** (shared by its
profiles), `WidevineCdm/<version>/_platform_specific/mac_arm64/`. This is not
`<profile>/WidevineCdm`. On macOS the installer registers the CDM dynamically;
Linux's startup hint file is not needed. Reload a page which previously failed
EME negotiation after installation. No copying from the owner's Chrome is needed.

Prefer the existing authenticated CRX installer over a bespoke zip downloader:
keep signature verification, sandboxing, manifest checks, updates and diagnostics.
Airc previously explicitly built with `enable_widevine=false`. At the start of
this investigation, BACKGROUND-SERVICES.md and the source **retained** the shared
component updater, contrary to the initial brief. The first DRM pass restricted
that updater because the brief requested it. The completion pass reverts this
security regression: all prior component registrations, URLs, pings and download
behavior are restored. Only Widevine's update requests are gated by its switch.

## Other browsers (facts, with limits)

- **Brave:** [official help](https://support.brave.app/hc/en-us/articles/360023851591-How-do-I-view-DRM-protected-content)
  documents opt-in Widevine and reinstalling the component. The inspected
  `brave-core` tree gates `RegisterWidevineCdmComponent` on its enabled preference,
  requires encrypted component transport and adds signing integration in
  `chrome/installer/mac/signing/parts.py`. Its build/signing integration is
  evidence of infrastructure, not permission for Airc to reuse Brave signatures.
- **Vivaldi:** [official help](https://help.vivaldi.com/desktop/media/widevinecdm-eme-drm-netflix-amazon-spotify/)
  directs users to `vivaldi://components` to install/update Widevine and names
  Netflix, Prime, Spotify and Tidal. This verifies component delivery; it does
  not establish contractual terms or guarantee every quality tier.
- **Opera:** [Netflix's Opera troubleshooting](https://help.netflix.com/en/node/40838)
  directs users to update Widevine through `opera://components`. This verifies
  the component workflow, not Opera's private licensing/signing arrangement.
- **Thorium:** its [GN argument documentation](https://thorium.rocks/docs/about_gn_args.html)
  and [FAQ](https://thorium.rocks/faq) describe enabled Widevine and limitations
  without VMP, especially on Windows/macOS. Bundling/support flags do not imply
  Netflix compatibility. Thorium is not evidence that Airc can skip certification.
- **ungoogled-chromium:** read-only inspection at
  `28a211ab4ab6b83d919966a4f58a6df23cf4fb29` found `enable_widevine=true` in
  `flags.gn`. Its [installation FAQ](https://ungoogled-software.github.io/ungoogled-chromium-wiki/faq#how-do-i-install-widevine-cdm)
  describes manual installation; enabling EME support is distinct from obtaining
  a binary. Platform packagers may differ.
- **Helium:** read-only inspection at
  `2f81b9cafa38a95071e20de3f9cd6b0aca6d3c65` found the same GN flag. Its
  [`component-updates.patch`](https://github.com/imputnet/helium/blob/2f81b9cafa38a95071e20de3f9cd6b0aca6d3c65/patches/helium/core/component-updates.patch)
  routes component requests through consent-gated Helium services and permits
  only CRLSet and Widevine at the component installer registration entry point. This does not establish
  VMP certification or commercial-service playback. Both GPL trees were read
  for behavior only; Airc's implementation uses Chromium's own interfaces.

## VMP is separate from CDM installation and Apple signing

Chromium's [`media_options.gni`](https://chromium.googlesource.com/chromium/src/+/156.0.8078.88/media/media_options.gni)
only defaults `enable_cdm_host_verification` on for branded Mac/Windows builds.
Widevine signing produces additional signature files for host binaries. An Apple
Developer ID signature/notarization does not supply these signatures; setting a
GN flag without certification/keys does not create a verified host. Do not copy
another browser's signatures, modify the CDM or spoof a certified host.

[Castlabs EVS](https://github.com/castlabs/electron-releases/wiki/EVS) provides
production VMP signing of macOS/Windows applications derived from its official
Electron for Content Security releases, free with signup. **Custom Chromium
adaptations require its commercial 3PL certification** before EVS can sign them.
Airc embeds a custom Chromium framework; ordinary EVS signup is not sufficient.
Ask about Airc's executable, helper and framework layout, arm64 support, release
cadence and the signing order relative to Apple's final codesign/notarization.

[Vuplex's engine documentation](https://support.vuplex.com/articles/how-to-enable-widevine/)
explicitly identifies Netflix as requiring VMP on Windows/macOS, unlike simply
installing the CDM. This is vendor experience, not Netflix's complete current
license policy. Netflix is therefore a likely certification blocker. Spotify's
[own help](https://support.spotify.com/us/article/web-player-help/) associates the
reported error with missing/disabled Widevine; it does **not** promise playback
from every unsigned Chromium embedder or publish its VMP policy. Spotify is a
candidate for playback without VMP, not yet a verified success.

Disney+, Prime Video, Apple Music web and Tidal may apply different license,
robustness, HDCP, codec, subscription, geography and browser policies. Their
current VMP requirements are **unverified here**. Do not label them all working,
or all VMP-blocked, from an EME capability probe. Public Shaka demo playback
qualifies the pipeline only; a non-enforcing demo license is not service approval.

## Licensing: release gate for the owner

Chromium's [Widevine LICENSE](https://chromium.googlesource.com/chromium/src/+/156.0.8078.88/third_party/widevine/LICENSE)
reserves the proprietary CDM to Google and requires a separate Google agreement
for use or distribution. Google's [Widevine overview](https://developers.google.com/widevine/drm/overview)
also says a license agreement is required. Chromium's BSD licence and Airc's
Apache licence do not cover the CDM. End-user CDM terms are not evidence of a
browser vendor's redistribution rights.

**No verified exception was found for a public browser that downloads the CDM
at runtime instead of bundling it.** Runtime download avoids shipping the binary
in Airc's package; it is not a demonstrated licensing exemption. Before public
release, the owner must contact Google Widevine, describe runtime component
installation/default-on behavior, obtain the applicable browser integration/use
agreement (or written confirmation of an applicable arrangement), and determine
required notices/end-user terms. Confirm commercial certification/VMP with Google
or Castlabs separately. Do not assume free licensing, approval or a timeline.
H.264/AAC patent/licensing questions remain separate. No agreement was accepted,
account created, or paid service purchased during this investigation.

## Implemented policy and validation

The release engine compiles EME/Widevine support without bundling. All pre-existing
component registrations and updater behavior are retained. Only disabled
Widevine is omitted before request assembly. Widevine's checks, pings and payloads
require HTTPS; its payload uses the direct downloader. Other components retain
their upstream networking. It persists a default-on,
engine-wide protected-content setting in Chromium Local State; apply it to each
loaded/new profile's encrypted-media preference. Expose the setting to the shell,
which owns the Privacy UI. Turning it off must stop future CDM update requests;
reload pages/restart to destroy existing CDM sessions and in-flight work.

Record separately: build success; CDM version/registered components; EME access;
license message; public encrypted playback with time advancing; off/restart
behavior; observed update hosts. Never use capture devices or account credentials.

## macOS hardened runtime (additional source finding)

[Apple's library-validation documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation)
explains that hardened processes ordinarily load only Apple-signed or same-Team-ID
libraries. Airc's normal utility helper and Google's CDM have different signing
identities. The original release signer forbade the corresponding runtime exception.
The completion pass adds it only to the CDM utility helper in both final signing
paths, with a gate rejecting it elsewhere. A disposable Developer ID host passed
encrypted playback and Apple notarization. This addresses the loader boundary,
not VMP certification; see PASS-DRM.md.

## Update endpoint probe (not a browser playback result)

On 2026-11-06 a protocol-4.0 request matching Chromium 156's request format,
for mac/arm64 and only Widevine, returned version **4.10.3112.0**, status `ok`.
Its HTTPS CRX3 download was 20,423,379 bytes, SHA-256
`6bf32d10630d5aebe1ae2aafb510f43801347c30d012932764e63b5513325af4`, matching the
update response. Metadata inspection found the expected mac_arm64 dylib and
signature, interface version 10, host versions 10/11, cenc/cbcs and no persistent
license support. Its bundled LICENSE repeats the separate-agreement requirement
above. The response offered both HTTP and HTTPS CDN URLs. In this Chromium pin,
`RequiresNetworkEncryption=true` covers checks/pings, so Airc additionally filters
the payload URLs in the download pipeline. Native installation must verify the
CRX signer, compatibility and loading; this metadata probe does not replace that.
The binary was not bundled or installed by the probe. Evidence is in the private
implementation report's artifact directory, not committed to the browser repo.

## Runtime result, 2026-11-06

The completed macOS arm64 release engine installed **4.10.3112.0** through the
native component updater in an isolated ad-hoc host. EME access, MediaKeys and a
license-request message succeeded. The public Shaka Angel One Widevine stream
obtained a license and played with advancing time. Disabled EME rejected access,
and the persisted off state produced no component requests over the initial
update interval. See PASS-DRM.md for the complete qualification and signing limits.
This does **not** qualify the owner's Developer ID app or any subscription service.

# Airc release runbook


## Release stable 0.1.0

From a green HEAD, with signing in the private `airc.env` beside the checkout and
Blob configuration in `../secrets/public-release.env` (mode 600):

```bash
scripts/release/release.sh
scripts/release/upload.sh --go
```

The first command builds, notarizes, tests and stages the committed source. The
second uploads the last staged **stable** release, verifies remote hashes, and
prints the direct HTTPS DMG URL. An explicit staging folder is also accepted.
Neither command deploys the homepage. `upload.sh STAGE --verify-only` never writes
to Blob. A failed source suite blocks upload by default. Only an explicit owner
exception may use `--accept-red-suite "REASON"`; it requires the actual failing
check names in `evidence/source-suite.txt` and writes the reason, failures, source
revision and exact DMG hash into private evidence and `release.json`. It never
bypasses scanning, metadata, notarization, quarantine, install or Sparkle gates.
The first 0.1.0 candidate has this explicit exception, not a claim of a green suite.

Until `aircbrowser.com/appcast.xml` is deployed, automatic update checks fail
quietly and retry later. Browsing and installation continue normally. Manually
choosing Check for Updates may show Sparkle's normal network-error message.

Packaging runs on the build Mac. `release.sh` orchestrates it from the Linux box;
only `upload.sh --go` publishes public artifacts. The private dev channel is separate. The app's Sparkle wiring is applied (`AppDelegate`, `AircUpdateDelegate`,
`scripts/build-app.sh`; the old `app-wiring.patch` and `dev-channel.patch` are in git
history). Test bundles stay ad hoc. Published dev bundles can be re-signed with Developer ID after testing;
public packaging supports Developer ID and notarization of both the app and DMG.

## Versions and channels

Recommend SemVer for `CFBundleShortVersionString` (0.1.0, then 1.0.0), and strictly
increasing UTC `YYYYMMDDHHMM` for `CFBundleVersion`. Do not issue different builds
within the same minute. Sparkle compares build numbers. Record the source commit
and full Chromium version in release notes. Never downgrade Chromium profiles.

This task's **stable** and **nightly** replace the earlier spec's beta terminology.
Use separate local staging folders but one public `/appcast.xml`, with explicit
`sparkle:channel` tags for stable and nightly. Settings → General selects Stable
(default) or Nightly; Nightly allows both tags. The uploader merges the live feed
at promotion time and retains four items per channel. Dev only accepts dev. Promote with a new,
higher build number after smoke tests and normally one day of owner use; expedite
actively exploited security fixes. Do not rename or mutate published artifacts.

## Tools and EdDSA keys

Run `scripts/release/setup-sparkle.sh` to download official Sparkle 2.10.1 into
`~/arcfork/tools/sparkle`. The script pins the observed archive SHA-256. Upgrades
require intentional review and repinning. No Homebrew, sudo or global install.
Keep Sparkle's bundled licence and framework notices when redistributing.

Normally run `~/arcfork/tools/sparkle/bin/generate_keys` in an interactive Mac
session. It stores the private seed in the login keychain. Only the public key
belongs in `infra/release/sparkle-public-key.txt`.

During this task the login keychain returned -25308 over SSH. The owner authorized
a file fallback. `swift infra/release/file-key.swift` generates a CryptoKit Ed25519
seed in Sparkle's supported base64 32-byte format, preserving any existing seed.
It lives only at `~/arcfork/secrets/sparkle_ed25519_private`, directory mode 700,
file mode 600. It was never copied off the Mac, printed or committed.

**Owner migration while logged in at the Mac:**

```sh
~/arcfork/tools/sparkle/bin/generate_keys -f ~/arcfork/secrets/sparkle_ed25519_private
~/arcfork/tools/sparkle/bin/generate_keys -p
# Compare against infra/release/sparkle-public-key.txt and back up the keychain.
# Only after successful import and comparison:
rm ~/arcfork/secrets/sparkle_ed25519_private
```

If an existing key conflicts, stop and reconcile public keys; never delete an
unrelated key. `appcast.sh` prefers the keychain and verifies its public key. If
unavailable it uses the owned mode-600 fallback, verifies the derived public key,
and passes its path via `--ed-key-file`. Overrides: `SPARKLE_ROOT` and
`AIRC_SPARKLE_KEY_FILE`. Never pass private key contents in shell arguments.

## One-time Apple owner steps

1. Enroll in Apple Developer Program. Create a **Developer ID Application**
   certificate and install it with its private key in the build Mac's keychain.
   Check `security find-identity -v -p codesigning`.
2. In an interactive Mac terminal run
   `xcrun notarytool store-credentials "$AIRC_NOTARY_PROFILE" --keychain "$AIRC_SIGN_KEYCHAIN"`. Supply the requested Apple ID,
   team and app-specific password, or use an App Store Connect API key via
   `--key`, `--key-id`, `--issuer`. Keep credentials outside the repository.
3. The permanent public bundle identifier is **`com.aircbrowser.Airc`**, confirmed by the owner (spec D8).
   `stable-metadata.py` sets it on the freshly compiled public staging copy; test identities are never inherited.
4. Local Mac passkeys use the signed main app's `<team>.<bundle id>.webauthn` Keychain group.
   `sign.py` derives it from the embedded Developer ID provisioning profile when granted; no manual entitlement
   file is needed. iCloud Keychain additionally needs Apple's managed browser capability. Follow
   [the passkeys setup](../engine/PASSKEYS.md#icloud-keychain-owner-step), then regenerate the profile.
   The signer adds `com.apple.developer.web-browser.public-key-credential` only if that profile grants `true`.
   `passkeys-template.entitlements.plist` is documentation, not an automatic entitlement grant.
   Manual `AIRC_PASSKEY_ENTITLEMENTS` extras must also fit the embedded profile; ad-hoc use is refused.
5. Select hosting and authorize public launch separately. The planned production
   feed is not live. Use a private HTTPS feed override until launch.
6. iCloud sync (below): the `iCloud.com.aircbrowser.Airc` container, the App ID's iCloud capability with CloudKit
   (optionally Push Notifications), a Developer ID provisioning profile in `~/arcfork/secrets/`, and the CloudKit
   schema deployed to Production ([sync.md](sync.md), "Deploying the schema").

## iCloud sync

Settings → Sync uses CloudKit's private database ([sync.md](sync.md)). CloudKit needs entitlements that only a
provisioning profile grants, so `package.sh` adds them when, and only when, a profile for the staged bundle ID exists:

- `scripts/release/icloud.py prepare` looks in `AIRC_ICLOUD_PROFILE_DIR` (default `~/arcfork/secrets`) for a
  `*.provisionprofile` (decoded with `security cms -D`) whose app ID is `<team>.<bundle id>`, that is a Developer ID
  profile (`ProvisionsAllDevices`), unexpired, with the `iCloud.<bundle id>` container and CloudKit. The newest match
  is copied to `Contents/embedded.provisionprofile` **before signing**. Anything else (no file, an expired profile, a
  dev bundle's, one without CloudKit) prints one line and the release is unchanged. A matching profile that can't
  grant what's needed (no Production environment, another keychain group) fails the release: fix the profile.
- Only the **main app** gets the extra entitlements (`sign.py` merges them like the passkey ones; list values such as
  `keychain-access-groups` are joined, so one profile can grant passkeys and iCloud): `com.apple.developer.icloud-services`
  = CloudKit, `com.apple.developer.icloud-container-identifiers` = the container,
  `com.apple.developer.icloud-container-environment` = Production (`AIRC_ICLOUD_ENVIRONMENT=Development` for a test
  build), the application and team identifiers, `keychain-access-groups` = `<team>.<bundle id>` for the synchronizable
  group key, and `aps-environment` when the profile has Push Notifications. Helpers, the framework and Sparkle get none.
- After signing, `icloud.py verify` compares `codesign -d --entitlements` of the main app with the embedded profile's
  entitlements and fails if any is outside the profile, if any nested code has iCloud or Keychain entitlements, or if
  the profile doesn't contain the certificate the app was signed with. That last one passes every signature check and
  then macOS refuses to launch the app (AMFI -413 "No matching profile found"); regenerate the profile with the build
  Mac's Developer ID certificate.
- Team and application identifiers are read from the profile at build time. They're never printed or committed.

Ad hoc packaging never looks for a profile. Without the entitlement the app says "iCloud sync is available in release
builds once set up" and never touches CloudKit (`SyncCapability`).

## Release gates

### Tests at release time: fast gate, changed-path smokes, tail

A release tests its cut in three steps. Only the first two hold the release.

1. **Fast gate** (`infra/release/fast-gate.py`, about 4 min): launch and quit, HTTP/HTTPS, Notes across a relaunch,
   the real Little Airc key, a real full-screen exit, local sharing, PiP, onboarding and redirects, on both engines.
2. **Changed-path smokes** (`infra/release/smokes.py`, budget 15 min): the core set (windows, sidebar, Command Bar,
   sign-in prompts; both engines), plus each smoke whose product paths changed since the last release. Security
   picks (outside-agent approval) and engine picks always run. When the picks exceed the budget, the lowest-ranked
   ones move to the head of the tail. **Headline checks** don't: a check that is new or changed since the last
   release (on the `--extra` freeze list with its owner's PASS count, a new script, or a new or edited catalog
   entry) and whose own product paths changed always runs at the gate. The plan raises the budget by their cost
   (and only theirs), names them as HEADLINE and records them in `budget_raised`. An edit to an existing Debug check
   alone (a check fix) is not a headline; list the check in `--extra` to make it one. On the signed stage, only the short functional smokes (ctxmenu, ctxmain,
   feedback, fedcm, mcpprompt, atlaunch, wkrules) hold the release.
3. **Tail** (after LIVE, on the same test build and stage): every other smoke from the catalog, the changed
   checks' own test code, the posted/real twins of gate runs, and the timing runs (cbperf, idlecpu, timelines,
   linkpaint, launchcount). A red tail does not hold the release that started it. It blocks the **next** release
   (`smokes.py blockers`) until the red is fixed on main, passes on a rerun, or is ruled under the flake rule.

A crash, hang or watchdog red stops the release at any step, and the flake rule never clears it. A new crash
report on the Mac during the smokes is the same kind of red. A check that crashes on purpose (chromeaccept's
`chrome://crash`) moves its own reports with `infra/release/smokes/mac-helper.sh sweep <marker> <dest> <n>`, which
waits for ReportCrash (it writes about 25 s after the crash); a sweep run right after the check missed one in the
0.1.63 tail.

```
python3 infra/release/smokes.py plan --to <cut> [--extra extra-oe-smokes.txt] [--allow ID=REGEX[:MAX]]… --json plan.json
python3 infra/release/smokes.py run --plan plan.json --tier gate --work <release> --out <dir> --during-staging [--groups g.tsv]
systemd-run --user --unit=<release>-tail --collect python3 infra/release/smokes.py run --plan plan.json \
  --tier tail --work <release> --out <dir> --release <version>   # after LIVE
python3 infra/release/smokes.py blockers      # the next release, before it freezes
```

`plan` compares the cut with the last release's `Source:` line in `docs/release-notes-beta.md`. It lists the
changed paths that no smoke covers, and any new check without a catalog entry. Add new checks with `--extra` (the
release074 `extra-oe-smokes.txt` format) and the PASS count their owner reported. Add `paths=GLOB,GLOB` (`S/`, `K/`
prefixes) to an extra line when the catalog has no entry for its script; without paths the plan can't tell whether
it is a headline check and says `HEADLINE?`. The catalog (`infra/release/smoke-catalog.json`) records each smoke's
paths, PASS floor and time. It also lists the standing FAIL-ENV notes (`allow_env`), which excuse a note printed
besides the PASS lines and leave the want as it is.

A lead-ruled line goes in with `--allow ID=REGEX[:MAX]` (ID is a case, e.g. `agentpane2-real`, or one engine's run,
e.g. `webkit-agentpane2-real`; MAX defaults to 1). Give it to `plan` at the freeze, so the plan json's `allow` list
carries it to both tiers (`run --allow` adds more). Each FAIL line it excuses stands for a PASS the check didn't
print, so it also lowers that run's PASS want by one: a run whose only FAILs are ruled lines is green. It stays
strict: any other FAIL, a missing PASS beyond the excused lines, or more matches than MAX (then none is excused) is
red. Each result in `gate-smokes.json` / `status/release-tail.json` records `want`, `want_effective` and the
`allowances` it used, and the state's `allow` lists every rule the run had. The plan warns about an `--allow` ID
that matches no run. Before a stage,
keep the test build's apps and scripts (about 0.7 GB) rather than deleting the work folder: the tail runs on them.
See `infra/release/fast-gate.md`, "Changed-path smokes".

### Packaging and distribution gates

`package.sh` builds the Chromium app from `out/AircRelease` (or explicit `CHROMIUM_OUT`) as a **public build**
(below) with the public stable feed, no dev channel, no bundle launch defaults and no test identity. `--app` uses an
existing bundle but rejects incorrect release metadata rather than rewriting it. Neither mode publishes. The staging
app is checked and scanned before signing; the final DMG is verified, scanned and checked again, mounted read-only.
Privacy strings come from the source plist and are not replaced during packaging.

- `scripts/release/check-release.sh APP_OR_DMG` (`check-release.py`): Chromium engine, public feed, stable channel, no
  dev-channel or launch-default keys, complete licence texts, a generated Chromium credits page, **no test code in the
  app executable**, and **engine test switches only together with their run-time gate** (both below).
- `scripts/release/scan-bundle.sh APP_OR_DMG` is deliberately strict: it reports file and category without printing
  the matched value, scans binary/UTF-16 text and symlink targets, and fails on home prefixes, tailnet hosts, private
  addresses and dev/test-default key literals. It does not decode compressed resources inside the app or replace a
  secret scanner.
- **A DMG is scanned by what it contains** (`scan-bundle.sh FILE.dmg`, also run by `package.sh` on the final DMG):
  1. every file of the volume, read through a read-only `hdiutil attach -readonly -nobrowse -noverify` mount on macOS,
     or a 7-Zip extraction elsewhere (`AIRC_7ZZ`, `7zz` or `7z`; 25.01 works, and the true symlink targets come from
     its listing). That covers the app with the allowlist above, and also `.DS_Store`, `.background/`,
     `.VolumeIcon.icns` and anything else, with no allowlist. Only the volume's own `Applications → /Applications`
     link may point outside it.
  2. the image's own bytes outside its compressed chunks: koly trailer, XML plist/resource fork, raw chunks, the code
     signature and any gap.
  The compressed chunks' payload (lzfse/lzma/zlib/bzip2/ADC, per the image's blkx table) is not matched as text: it
  is effectively random, so the old raw scan matched six random bytes as an IPv6 ULA in 0.1.29, 0.1.30 and 0.1.37,
  and real text inside it is never visible anyway. That is safe only because step 1 scans the decompressed files.
  If the contents cannot be read (no hdiutil or 7-Zip, attach fails, no app in the volume, malformed UDIF map) the
  scan fails closed: `DMG scan: FAIL: DMG contents not scanned (…)`. No exemption is needed for compressed noise; a
  DMG hit is now always a real file or metadata hit.
- The writable image is mounted at the default `/Volumes/Airc` while `layout.py` writes `.DS_Store`: the background
  picture's alias records the mount-point path, and a mount under the build folder put the build account's home path
  into every DMG up to 0.1.37 (found by the contents scan).
  Reviewed false positives are listed in `scripts/release/scan-allowlist.json`, one entry per finding with its reason.
  An entry covers only `home-path`, in one exact file, as a bare NUL-terminated C string (nothing after `/Users/`)
  inside the named Mach-O sections, at most `count` times; a longer path, another section, one more occurrence, a
  UTF-16 copy or any other file still fails. Allowed findings print as `ALLOW` with the reason, never the value. The
  one entry today is Chromium's `components/url_formatter/url_fixer.cc` `FixupHomedir` root (`kHome`, where a typed
  `~otheruser` path expands), [engine follow-up](../engine/LAUNCH-QUALIFICATION.md). Add entries only after review.
- `scripts/release/smoke.sh FILE.dmg [OUT]`: the launch smoke for a public build, which has no scripted scenarios.
  It mounts the DMG read-only, opens the app with `open -g` (never focused) on a scratch home and data folder with
  Chromium's mock keychain, waits for its window, checks it stays up, and quits it as the Quit menu does. A second
  launch passes `--snapshot`, `--script`, `--automated`, `AIRC_AUTOMATED=1` and the engine's trace switch on a scratch
  profile its gate would accept: the public build must ignore all of them. `prove-dmg.sh` adds codesign and Gatekeeper
  evidence to the smoke.

The app build maps Swift file/debug prefixes and strips linker debug records from release executables before
signing. Licence copying preserves Airc LICENSE/NOTICE, the full pinned Sparkle distribution LICENSE when embedded,
Chromium LICENSE (a pinned 156.0.8078.88 fallback is available for WebKit-only development), and the build's
generated credits HTML. An engine built without `generate_about_credits` has Chromium's 401-byte sample page; then
`package.sh` runs `chromium-credits.sh`, which makes the page from the engine's own checkout with Chromium's
`tools/licenses/licenses.py` and the arguments of its `about_credits` action, and ships that in
`Contents/Resources/Licenses/Chromium-credits.html`. The engine's own `chrome://credits` stays the sample until the
engine is rebuilt with `engine/build.sh` (which enables it). Offline About/Licences UI access and reciprocal
dependency obligations remain release qualification work.

## Public builds: no test code

The app's test code compiles only with the Swift condition `AIRC_TESTING`:

- `scripts/build-app.sh` passes `-D AIRC_TESTING` to every build (dev, nightly, snapshot suite, perf, update proofs),
  so the scripted suite and agents work unchanged.
- `AIRC_PUBLIC_BUILD=1 scripts/build-app.sh` (what `package.sh` runs) leaves it out, refuses `--snapshots`,
  `AIRC_LAUNCH_ARGS` and `AIRC_BUNDLE_ID`, and builds in its own SwiftPM folders (`build/.swiftpm-public`,
  `build/.swiftpm-chromium-public`) so neither variant invalidates the other's cache. A plain `swift build` is public.

Without it the app has none of `Sources/Airc/Debug` (each file is wrapped in `#if AIRC_TESTING`: the scenarios and
real-event checks, the synthetic Arc import fixture and Keychain-free credential check, the loopback page server,
perf and frame measurement with its control file, launch diagnostics), no `--snapshot`, `--script`, `--automated`,
`--onboarding` or `--perf-*` options, no `AIRC_AUTOMATED` and no bundle default options (`AircLaunchArguments`); no
synthetic-key import entry point, no canned suggestions, no update-proof auto-restart, and none of the
`ForTesting` engine wrappers or test-only actions. `LaunchOptions.isAutomated` and `isScripted` are the constant
`false`, so their branches compile away. Public builds also forward no `--airc-…` switch to the engine (below).
`App/TestingGate.swift` keeps the only stand-ins: no-op `testAnchor` view modifiers and a pass-through `Perf.time`.
DevTools and every user feature are unchanged.

`check-release.py` fails a public bundle whose `Contents/MacOS/Airc` still names a test-only type (Swift type
metadata keeps names after stripping) or a test option's longer literal. Swift stores literals of 15 bytes or fewer
(`--snapshot`, scenario names) inside instructions, so they can't be found by bytes; the types that parse and run
them can. Every dev/test bundle from `build-app.sh` fails this check by design.

## Engine test hooks

Today's engine (`out/AircRelease`) still compiles its harness switches in (engine/core/airc_launch_switches.h).
Compiling them out needs a separately configured engine build (about 2.5 h on the build Mac) and is not done yet.
What protects a release instead:

**1. The app never forwards them.** A public Airc.app drops every `--airc-…` argument before starting Chromium
(`LaunchOptions.forwardsToEngine`), so `--airc-test`, `--airc-trace`, `--airc-background`, `--airc-switches` and
`--airc-data-dir` can't reach the engine through Airc's own launch. The smoke's second launch checks the trace
switch on a scratch profile the gate would accept.

**2. The engine's run-time gate.** `--airc-test=<key[=value],…>` (`TestFlag`/`TestValue`) and
`--airc-trace=<area,…>` (`Traced`) are honoured only by a *test instance*, decided once per launch
(`TestGateRefusal`). It refuses, in this order:

| Refusal (logged) | Condition |
|---|---|
| `not the browser process` | any helper process |
| `signed for distribution` | the running app satisfies `anchor apple generic and (certificate leaf[field.1.2.840.113635.100.6.1.9] exists or certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists)`: Mac App Store or Developer ID. If the signature can't be read or the requirement can't be built, it counts as distribution (fails closed). |
| `not on the mock keychain` | no `--use-mock-keychain` |
| `--user-data-dir isn't the scratch data dir's Chromium folder` | `--user-data-dir` doesn't resolve (real path, existing) to `<--airc-data-dir>/Chromium` |

A refused launch logs `[airc] --airc-test and --airc-trace ignored: not a test instance (<reason>)` and runs
normally. Every engine `…ForTesting` API the app could call (`modalDialogStateForTesting`,
`cancelModalDialogForTesting`, `respondToModalDialogForTesting:`, `selectHybridMechanismForTesting`,
`simulateMemoryPressureForTesting:`, `loadUnpackedExtensionForTesting:`) and the test media-route, Bluetooth
chooser, external-protocol, system-permission and keychain-file hooks check `TestFlag`/`TestInstance` first. Separately,
without `--use-mock-keychain` the engine strips Chromium's profile-opening switches (remote debugging, extension
loading, proxy and host rules, certificate-error bypass, `SSLKEYLOGFILE`, …) at startup (`KeepRealProfileClosed`).

**Not gated:** `--airc-background` (the engine host's no-focus mode: a fixed eye-dropper colour, context menus through
the host, background picture-in-picture placement, a CHECK on unimplemented AppController selectors) and
`--airc-switches` (on/off overrides for the engine's quiet-mode and PiP switches). Neither reads profile data or the
Keychain, neither is a test hook a page can reach, and point 1 keeps both out of public Airc.app, so the engine is
unchanged.

**The ad-hoc friends beta** is not signed for distribution, so refusal 2 doesn't apply to it: there the protections
are point 1 and refusals 3 and 4, which keep any test instance on a mock keychain and a scratch profile, away from
the user's own. `check-release.py` fails a framework that contains the `airc-test`/`airc-trace` switch names without
the gate's requirement and refusal strings (proof the gate is linked in, not that it runs).

**Verifying on the first Developer ID build** (owner steps done, before publishing):

1. `codesign -v -R='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' --deep --strict Airc.app`
   on the packaged app: exit 0, so refusal 2 will apply.
2. The engine gate itself, past the app's filter: build a *test* build signed with the same identity
   (`SPARKLE_ROOT=~/arcfork/tools/sparkle AIRC_SIGN_IDENTITY=- scripts/build-app.sh`, then
   `python3 scripts/release/sign.py build/Airc-Chromium.app "$AIRC_SIGN_IDENTITY"` with the dedicated keychain
   environment configured), make `<scratch>/Airc/Chromium`, and
   launch it with `open -g -n --stderr <log> --env CFFIXED_USER_HOME=<scratch> build/Airc-Chromium.app --args
   --data-dir <scratch>/Airc --use-mock-keychain --airc-data-dir=<scratch>/Airc --airc-trace=profileGate
   --airc-test=modalDialogs`. The log must contain `ignored: not a test instance (signed for distribution)` and no
   `[airc] profile gate` line. The same launch of an ad-hoc test build must print the trace (control).
3. `--snapshot --script dialogs` on that Developer ID test build (as in `build-app.sh`): the checks that read the
   engine's dialog state must fail or skip, because `modalDialogStateForTesting` returns empty.
4. Remote debugging on the real profile: launch the *public* Developer ID app on a scratch home without
   `--use-mock-keychain` and with `--remote-debugging-port=9222`; `lsof -nP -iTCP:9222 -sTCP:LISTEN` must be empty.
5. Rerun `smoke.sh` and `check-release.sh` on the notarized DMG.

Defense in depth still wants the separately configured engine build that compiles these hooks out; until then,
describe them as runtime-gated, never as compiled out.

## Per-release procedure

Build reviewed source, run app and engine acceptance tests (the scripted suite runs on a dev/test build:
`scripts/build-app.sh --snapshots DIR`), and verify the engine version, licence notices, bundle ID, feed URL,
public key and increasing version. `package.sh` makes its own public build; it never packages a test build:

```sh
# Local ad-hoc candidate (Chromium from out/AircRelease, public stable feed). A copy without .git passes its commit.
caffeinate -i -s env AIRC_SOURCE_REV=<commit> scripts/release/package.sh --output build/release
scripts/release/smoke.sh build/release/Airc-VERSION-BUILD.dmg

# Distribution after Apple setup:
scripts/release/package.sh \
  --identity "$AIRC_SIGN_IDENTITY" \
  --notary-profile "$AIRC_NOTARY_PROFILE"
```

`--app` selects another input app; `--output` selects the destination directory.
Packaging copies the input into staging without mutating it. Camera/microphone
usage strings go in Info.plist, not entitlements. Real Mach-O files are signed
first, then nested helpers/XPC/apps, frameworks and the outer app. Renderer/GPU
helpers receive allow-jit; the app receives Chromium's device entitlements.
Hardened runtime is always on. Only ad-hoc signing disables library validation;
Developer ID uses secure timestamps. No get-task-allow. Signing never uses
`--deep`; verification does.

`package.sh` takes its identity from `AIRC_SIGN_IDENTITY` (or `--identity`, default ad hoc), and
`sign.py` unlocks `AIRC_SIGN_KEYCHAIN` using `AIRC_SIGN_KEYCHAIN_PASSWORD_FILE` immediately before signing.
The password file must be owned by the build user, a regular file and mode 600; it is read only on the Mac.
All three values belong in private operator configuration, never source control.

Set `AIRC_NOTARY_PROFILE` to the stored profile name and `AIRC_NOTARY_KEYCHAIN` to its keychain (defaults to
`AIRC_SIGN_KEYCHAIN`). The dedicated keychain works over SSH; do not rely on the locked login keychain.
With a usable profile, the staged signed app is zipped, submitted with `notarytool submit --wait` and stapled
before building the DMG. The DMG is then signed, submitted and stapled too. An absent optional profile produces
a signed, unnotarized DMG and an explicit pending message. Authentication/network errors stop packaging.
An explicit `--notary-profile` is mandatory: missing credentials fail rather than falling back.
`notarize.sh` fetches Apple's JSON log and requires Accepted status before stapling. Logs are retained beside
the DMG (`app-notary-log.json` and `<dmg>.notary-log.json`). Nothing is uploaded to a distribution host.
Inspect rejected submission IDs with `notarytool log`; never publish on failure.
Standalone usage: `notarize.sh --profile NAME FILE.dmg`, or ZIP plus app target.
`--dry-run` prints arguments without credentials, files or a network submission.

The DMG uses APFS/ULFO compression, Airc's brand image and app icon, a soft gradient
background, and an Applications symlink. A native alias helper and dependency-free
single-leaf `.DS_Store` writer configure a 660×440 window with icon positions. No
Finder automation permission is needed. Writable temporary images are cleaned on
exit. The script refuses to overwrite an existing version/build DMG.

Verify the mounted app with `codesign --verify --deep --strict --verbose=2` and
`spctl -a -vv`. Validate both app and DMG tickets using `xcrun stapler validate`.
Also test a fresh quarantined download on a clean Mac: Gatekeeper must accept it.
Do not equate the ad-hoc fixture result with production notarization acceptance.

Copy the final stapled DMG into a channel's releases folder and generate the feed:

```sh
scripts/release/appcast.sh stable build/releases/stable \
  Airc-1.0.0-202701010100.dmg release-notes.md \
  https://aircbrowser.com/releases/stable/
```

The Markdown notes are copied alongside the named archive. Sparkle creates signed
enclosures, Markdown links and up to three deltas, retaining four versions. Keep
original prior archives for deltas. A local channel marker prevents accidentally
mixing folders. Sparkle may move older files to `old_updates`; retain published
URLs still needed by clients, but do not deploy that folder or the marker.
Archive/delta EdDSA signing is enabled; feed signing is not. HTTPS protects feed
and notes transport. Do not change payloads after appcast generation.

**Public repo synced to the release cut.** The site says Airc is Apache-2.0 and all of it open source, so
every release's source must be in the public repository when the release goes out. Once the cut is on
`origin/main`, the release agent runs, from the Linux checkout:

```sh
infra/launch/public-sync-check.sh <cut commit>   # must end "public-sync-check: PASS"
```

It checks `../status/public-sync.state` (last sync OK), that the published private revision contains the cut,
and that GitHub's public `main` is the commit that sync recorded. If it fails because the hourly sync hasn't run
since the cut, run the sync as cron does (the `sync-public.sh` line in `crontab -l`) and check again. If the
sync's privacy scan fails, the release waits: fix the finding in the private repo
([public-repo.md](launch/public-repo.md), "Made-up addresses"), push, sync, check. Record the PASS output
with the release evidence.

**Public release tag.** Reviewers (byearc.com among them) check features against the source, so each release
also gets a tag `v<version>` and a GitHub Release on the public repository whose tree is exactly the release's
build revision minus `infra/launch/exclude.txt` ([public-repo.md](launch/public-repo.md), "Release tags"). Once the
"Record the <version> release build identity" commit (the changelog's `Source: … Build: …` line) is on
`origin/main`, the release agent runs, from the Linux checkout at `origin/main`:

```sh
infra/launch/sync-public.sh --release <version>        # scans, pushes tag v<version>, creates the GitHub Release
infra/launch/public-release-check.sh <version>         # must end "public-release-check: PASS"
```

The release isn't done until `public-release-check.sh` passes, like the Vercel check: report its output with the
LIVE post. If the scan fails, the release waits: fix the finding in the private repo, push, and run both again.
Never delete or move a published tag; a wrong tag is the lead's call.

Test N−1 → N with real signed builds, both full and delta download, relaunch and
profile/settings preservation. Upload immutable DMGs, deltas and notes first;
verify their HTTPS downloads, then atomically publish the feed. Re-fetch and test
channel filtering. Save logs, checksums, feed and source/engine revisions. Never
publish test feeds or ad-hoc builds. Recover a bad release by withdrawing its feed
entry and shipping a higher fixed build, never downgrading user profiles.

## Earlier hosting options (superseded by Blob below)

**Vercel / aircbrowser.com:** add `/appcast.xml`, `/nightly/appcast.xml`, and
`/releases/{channel}/` artifacts to the existing project. Feed caching should be
short/no-cache; immutable artifact caching can be long-lived. Use appropriate XML,
Markdown and DMG content types. Before implementation check current plan limits,
asset sizes, bandwidth and range requests against the actual Chromium DMG. No
Vercel limits are assumed here. If large binaries do not fit, keep the feed on
Vercel and host its enclosures on GitHub Releases.

**GitHub Releases after the repository is public:** upload versioned DMGs, deltas
and notes to immutable release tags; use prereleases for nightly tags. Host feeds
on the stable domain via Vercel or GitHub Pages, referencing exact release asset
URLs via the appcast script's download prefix. Private repository assets are not
anonymous Sparkle hosting. Avoid authenticated/expiring URLs and `latest/download`
for immutable enclosures. Do not overwrite published asset bytes.

## Local proof and remaining qualification

```sh
scripts/release/package.sh
scripts/release/check-release.sh build/release/Airc-VERSION-BUILD.dmg   # package.sh runs both gates on the DMG too
scripts/release/scan-bundle.sh build/release/Airc-VERSION-BUILD.dmg
scripts/release/prove-dmg.sh build/release/Airc-VERSION-BUILD.dmg       # codesign, spctl, smoke.sh
infra/release/test-updater/run.sh
```

The fixture builds separate 0.0.1/build 1 and 0.0.2/build 2 apps with Sparkle,
signs them ad-hoc, creates an EdDSA feed and delta, and serves only on 127.0.0.1
at an ephemeral port. A non-activating custom Sparkle user driver accepts the
update into `build/updater-proof/installed`, checks relaunch and installed version,
then the runner stops the server. Its ATS exception exists only in this fixture.
It never modifies Airc. Archive/remove `build/updater-proof` before rerunning.
Keep logs with local paths outside public source control. Clean large test bundles
after saving evidence, but retain the key until successful keychain migration.

Verified 2026-11-06 (friends-beta candidate, ad hoc): `package.sh` from `f3c27e8` on `out/AircRelease` made
`Airc-0.1.0-202611061150.dmg`. On the final DMG `check-release.sh` and `scan-bundle.sh` passed (one `ALLOW`, the
reviewed `kHome` entry); `hdiutil verify` valid; deep strict codesign valid; `spctl` rejected (exit 3, expected for ad
hoc). `prove-dmg.sh`/`smoke.sh` passed both launches. The same build's test variant fails `check-release.py` on all
13 test markers and passes the suite (WebKit 108/0/16, Chromium 195/0/20 PASS/FAIL/SKIP). With the smoke's engine
switches a test build prints `[airc] profile gate at startup`; the public build prints nothing.

Verified 2026-11-05:

- Current WebKit build: `build/final-release/Airc-0.1.0-202611050248.dmg` passed
  `hdiutil verify`, mounted read-only, launched with `open -g`, captured its showcase
  screens under `build/dmg-proof/screenshots`, and quit.
- Deep strict codesign verification: `valid on disk` and
  `satisfies its Designated Requirement`, exit 0.
- `spctl -a -vv`: `Airc.app: rejected`, exit 3, expected for ad-hoc signing.
- A separate bundle with the actual Chromium framework and all helpers also passed
  deep strict verification. This was a signing check, not a Chromium launch test.
- Sparkle fetched the feed, Markdown notes and `UpdaterProof2-1.delta` (814 bytes).
  Result:

  ```text
  LAUNCHED 0.0.1
  CHECK
  FOUND 0.0.2
  DOWNLOAD
  EXTRACT
  VERIFIED; INSTALL AND RELAUNCH
  INSTALLING
  LAUNCHED 0.0.2
  PASS installed and relaunched 0.0.2
  ```

- Stable and nightly feed generation passed. Five invalid notarization argument cases rejected as expected.
- DMG and ZIP notarization argument dry-runs passed; real submission is untested.
- Finder AppleEvents timed out (-1712) in the locked session. No Finder-window
  screenshot was captured. The deterministic layout replaces that automation;
  visual presentation still needs an unlocked Finder check before distribution.
- Developer ID signing, passkeys, Gatekeeper acceptance and production hosting
  remain unqualified pending owner setup. Nothing was published.

### Stalled downloads: one retry

On some routes an update download stops mid-body: the far end drops the flow, and nothing arrives until the request
times out. Sparkle never retries; a failed delta falls back to the full archive once, then the update aborts.
`AircUpdateDelegate` adds two things (decision logic in AircKit `UpdateDownloadRetry`, unit-tested):

- Update downloads give up after 20 s without bytes (`URLRequest.timeoutInterval`, set in `willDownloadUpdate`)
  instead of 60 s.
- One background check 5 s after a cycle that ended in a download error caused by a timeout or a lost connection.
  Signature, validation, disk, HTTP and offline errors never retry, the retry's own failure never retries, and nothing
  retries while Sparkle's automatic checks or downloads are off. `Updates.log` gets one `download stalled (…):
  retrying once in 5 s` line per retry. A check the person started still shows Sparkle's error first; a successful
  retry then offers the update as usual.

Real updater proof (on the build Mac, under the UI lock): `infra/updates/retry-proof.py` updates a copy of a build
with the retry to a published archive, with its published signature, from a loopback appcast. `infra/updates/staller.py`
serves the archive and stalls the first GET mid-body. Its test is `infra/updates/test_staller.py`.
Run it inside `infra/release/update-proof.py --domain com.aircbrowser.Airc`: cfprefsd keeps `SULastCheckTime`
outside `CFFIXED_USER_HOME`, and without the wrapper the next proof's check is skipped for an hour.

Verified 2026-11-15 on the build Mac: a Developer ID signed public build of this change, stamped 0.1.0 (202611010000),
updated to the published 0.1.16 archive. The first GET stalled after 1 MiB; Sparkle failed it after 20 s, one retry
followed 5 s later, the update was ready 37 s after launch, installed on quit and relaunched. With every GET stalling,
it logged exactly one retry and then aborted with Sparkle's usual error.

### First launch after an update: warm-up

The first exec of a newly written copy of the signed app costs ~4 s in macOS before `main` (syspolicyd/AMFI evaluate
the new Airc Framework); the per-file results survive a rename. Sparkle 2.10 installs by swapping the bundle it
extracted and validated into place, and its first install stage already runs `gktool scan` on it (~3.7 s, macOS 14.4+,
same volume and team), so most of that cost is paid before Airc quits. Once Sparkle reports the update ready
(`willInstallUpdateOnQuit`), `UpdateWarmupRunner` (finding the staged bundle: AircKit `UpdateWarmup`) checks the
staged bundle's signature against Airc's own team and identifier and executes it once with the blocking-list check
child's arguments, which exit on the first line of `main` (no window, profile or network; killed after 30 s; quitting
never waits for it). `Updates.log`: `warm-up: signature checked in … s, probe exit 1 in … s`. `AIRC_UPDATE_WARMUP=0`
turns it off, `=check` checks without executing (A/B only).

Verified 2026-11-17 on the build Mac with real Sparkle updates (Developer ID builds 0.1.90 → 0.1.91 from a loopback
appcast, throwaway EdDSA key, inside `update-proof.py`, 5 runs per arm): first launch after install, pre-main 140–223 ms
without the warm-up, 54–68 ms with it (the second launch: 55–60 ms in both); a signature check alone 175–188 ms.
Report: artifacts/updatewarm.

References: [Sparkle setup](https://sparkle-project.org/documentation/),
[publishing](https://sparkle-project.org/documentation/publishing/),
[Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution),
[seed format](https://github.com/sparkle-project/Sparkle/blob/2.10.1/generate_keys/main.swift).

## Private dev channel and dedicated-host migration

The existing dev installation still reads the owner laptop's loopback feed. Its
LaunchAgent and feed stay intact while all new builds and tests move to the dedicated
Mac. The ship loop, nightly and publishing remain held until a green dry ship and
signed scratch dev-feed proof. Existing signed ZIPs and EdDSA deltas stay in `~/arcfork/updates-local/`. `infra/updates/local-feed.sh`
installs `~/Library/LaunchAgents/org.airc.devfeed.plist`, serving **only that
folder**, bound to **127.0.0.1:3483**. It uses the existing Python interpreter and
`server.py` copied into `~/arcfork/tools/devfeed/`; no new dependencies or root.
Launchd starts it at login and restarts failures. The installer keeps the existing
working Python path when login and non-login SSH shells have different PATHs;
bootstrap retries are bounded, and a unique file probe verifies the served folder.
`local-feed.sh --proof` tests a separate scratch service and loopback port 3493.
Every publisher failure logs its phase and exit status. The Linux coordinator
streams the Mac output into `publish-dev.log`, retains `publish.*/prepare.log`,
and surfaces the remote failure summary, so
redirected Mac errors cannot leave an empty `publish-dev.log`. Directory listings and symlink
escapes are refused (including HEAD requests). The existing loopback feed stays unchanged
until cutover. A separately rooted signed scratch dev feed may use tailnet-only HTTPS
Serve, with distinct frontend/backend ports; never Funnel. A service health probe
alone does not prove a signed app update. Server logs live beside its script.

Dev builds default to `http://127.0.0.1:3483/appcast.xml`. `nightly.sh` and `publish.sh`
read `LOCAL_FEED` from private operator configuration, retaining that compatibility
default until the feed bridge is qualified. An older `AIRC_UPDATE_FEED` does not override it.
The dev plist enables `NSAllowsLocalNetworking`; public builds retain their ATS
policy. Sparkle still verifies every archive and delta against the same EdDSA
public key. No certificate exception or trusted self-signed certificate is needed.
Apple documents local networking in [NSAllowsLocalNetworking](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking).

The operator's `airc.env` beside the checkout still sets `AIRC_DEV_CHANNEL=1`,
`LOCAL_FEED`, and optional `AIRC_MAC_HOST`, `AIRC_UPDATES_DIR` and `AIRC_STATUS_DIR`.
The dedicated host defaults to `buildmac`; signing configuration is sourced only there
from `~/arcfork/setup/signing/signing.env`. Set `AIRC_PUBLISH_HOLD=1` to refuse dev
and public release preparation before metadata/staging writes. Never commit operator
configuration; `AIRC_UPDATES_CONFIG` overrides its path. See [host routing](dev/build-mac.md).

**Switch-over.** Keep the Linux HTTPS service (`infra/updates/serve.sh`) running.
Each publish atomically mirrors the small appcast there; its newest enclosures
point to **the client's loopback server**, not Linux. The old app fetches this feed,
downloads the signed payload locally, and installs a build whose SUFeedURL is the
local feed. Older retained items can still name Linux archives. This is an
appcast bridge, not an HTTP redirect or a Sparkle preference change. It requires
the LaunchAgent to be installed first, which publication ensures. Keep the bridge
until the owner has restarted into a local-feed build; do not modify their app,
preferences, profile or Keychain to force migration. No large transition upload.

**Remove the service** on the build Mac:

```sh
launchctl bootout "gui/$(id -u)/org.airc.devfeed"
rm ~/Library/LaunchAgents/org.airc.devfeed.plist
# Once no installed dev app relies on it:
rm -rf ~/arcfork/tools/devfeed ~/arcfork/updates-local
```

Removing it stops dev updates until reinstalled or the app moves to another feed.

**Signing the owner's builds.** Ad-hoc signatures change code identity on every update, causing repeated
Keychain and TCC approvals. Use a Developer ID Application identity in a dedicated keychain on the build Mac.
Keep that identity and the bundle identifier stable. The keychain must be in the user's search list, contain the
Developer ID intermediate, and grant `codesign` noninteractive private-key access (partition list) once at setup.
The operator's private `airc.env` sets `AIRC_SIGN_IDENTITY`, `AIRC_SIGN_KEYCHAIN` and
`AIRC_SIGN_KEYCHAIN_PASSWORD_FILE` to the identity and Mac paths; it never contains the password itself.
Do not enable these until both Sparkle migration proofs and the signed launch smoke pass.

`nightly.sh` forwards these settings but explicitly builds and tests with `AIRC_SIGN_IDENTITY=-`, with WebKit advice confined to the full nightly run. `publish.sh` forwards them separately to `prepare-mac.sh`. After the tests, prepare
copies the tested Chromium bundle into staging and `sign.py` unlocks the dedicated keychain immediately before
signing that copy, inside out: real Mach-O files, nested helpers/apps/XPCs, frameworks (including Sparkle), then
the outer app. Developer ID uses hardened runtime, secure timestamps and no disable-library-validation.
The original bundle stays ad hoc so engine test hooks continue to work. Nothing weakens the engine's distribution gate.

The staged bundle must pass deep strict verification and the Developer ID requirement. `spctl -a -vv --type exec`
is saved as informational evidence: unnotarized Developer ID is rejected; notarized Developer ID is accepted.
The releasegate smoke runs in `--plain-only` mode: fresh scratch home, mock Keychain, a normal window, wait and
quit, with no scripted scenarios or engine test switches. The signature is checked again and its CDHash must be
unchanged after smoke. The exact staged bundle is then archived and EdDSA-signed for Sparkle.

**Owner, once after the first signed update:** answer Airc's Keychain question once (Allow or Always Allow; macOS
may show it twice), and re-grant the Bluetooth, microphone and camera permissions you use when macOS next asks.
- Keychain: an item trusts the build that made it, an ad-hoc maker by its cdhash and a Developer ID maker by its
  designated requirement. So after that answer, the first team-signed build makes "Airc Safe Storage" its own
  (`App/SafeStorageKey.swift`: same secret, new item), and every later launch and update reads it without asking.
  This was proven on scratch keychains (no UI, interaction off), never on the owner's.
- The stable Apple signing identity lets the TCC approvals survive updates. Tests never access media devices or
  change the owner's grants.

**What a dev build does** (`AIRC_DEV_CHANNEL=1 AIRC_UPDATE_FEED=… scripts/build-app.sh`): Sparkle is embedded from
`~/arcfork/tools/sparkle` and the bundles are signed by `scripts/release/sign.py`. `Airc-Chromium.app` gets
`AircDevChannel`, channel `dev`, `SUFeedURL` from the environment, automatic checks, `SUAutomaticallyUpdate` and a
3600 s interval. It checks at launch, every ten minutes, and after wake, and downloads by itself. Once Sparkle has downloaded the update and
checked its EdDSA signature against `SUPublicEDKey`, a toast and an app-menu item under "Check for Updates…" read
“A new version of Airc is ready. Restart to update”. Choosing the item installs the update and relaunches Airc
(Sparkle's immediate install, no further dialog), and quitting installs it too. Every step is appended to
`Updates.log` in the data folder. The WebKit `Airc.app` stays on the stable channel and checks only when asked,
because the dev feed carries Chromium builds. Scripted runs (`--script`, `--snapshot`: snapshots and perf)
never start the updater.

**The sidebar's update button** (Browser/UpdateButton.swift, Arc's "New Arc Version Available" pill). Dev builds
also check when Airc becomes active after the Mac wakes (10 s later, unless an update is already ready or a session
is running). Once Sparkle hands over its immediate-installation block (`ready …: installs on quit`), a 34 pt pill
above the footer's Space icons reads "New Airc Version Available" ("New Version Available" in a narrow sidebar,
"Restart to Update" under the pointer). It is part of the sidebar, so it also shows in the revealed sidebar while
the sidebar is hidden; the toast and the app-menu item stay. A click, or the menu item, first looks for what a
restart would interrupt: a page using the camera, microphone or screen, a running download, or a page that would ask
"Leave site?" (each page answers itself, 0.5 s at most). If there is any of these, a card above the button says what
would be lost, with Not Now (the default) and Restart. Restarting saves the Spaces store, as quitting does, answers
the downloads question already asked, and runs Sparkle's block. Sparkle then quits Airc the usual way, so a page can
still ask "Leave site?"; Stay cancels the quit and the button stays. Airc never restarts by itself: without a click,
the update installs at the next quit. There is no download progress (Sparkle tells the delegate only when a download
starts and ends); failures appear in `Updates.log` only. Telemetry: `update.ready_shown` once per version,
`update.restart_clicked` per click. `--script updatebutton` tests it all on a fake `ReadyUpdate`, never the real
updater or feed.

**The pill's highlight lines** come from the appcast item's `<airc:highlights>` (at most three: title, lead-in,
SF Symbol). `scripts/release/manifest.py` writes them with `whatsnew.appcast_lines`, from the first WhatsNew.json that
has the release: the staged app's (`stage/package/Airc.app` while worker.sh runs), then the tooling tree's
`apps/browser/Resources/WhatsNew.json` (a regeneration on Linux). So the icons are the ones picked for What's New.
Without an entry for the release, the lines come from the notes' "New since" section, and each takes the icon of a
WhatsNew.json line with the same lead-in or title; only a line nobody picked an icon for gets `icon_for`'s guess.
Until promptic, every appcast (0.1.13 on) carried the guesses, because manifest.py looked for the app at
`stage/Airc.app`, which never exists; 0.1.15, 0.1.16 and 0.1.17 differed from their What's New icons.

**Publishing.** Package tests and Chromium snapshot checks gate `--ship`.
`prepare-mac.sh` signs the tested copy and runs its launch smoke. `publish.py` runs
on the Mac, verifies EdDSA using CryptoKit (Linux tests use OpenSSL), validates
identity/channel/source, writes immutable enclosures, then atomically replaces
the appcast. It retains five releases. A first local publish seeds its history
from the old Linux feed so existing published delta sources remain eligible.
The acknowledged cache migrates to `~/arcfork/updates-cache.noindex/dev`; three
prior apps plus one pending candidate remain, all unregistered from Launch Services.
Only metadata (build, version, source, SHA-256, size, delta list), the appcast and
small text evidence return to Linux. Work pages retain their `Info.plist` evidence.
`infra/updates/publish.sh arcfork/nightly` can publish an already built candidate.

`defer-mac.sh` freezes dSYMs and snapshots as APFS clones in
`~/arcfork/update-jobs/<run>/` before nightly's next export removes the build.
After local publish and this local staging, `nightly.sh` releases the ship lock
explicitly, then renders status and starts `airc-deferred` in tmux. It never
refreshes the owner's try copies. The shipping loop no longer gates on uplink.
`deferred.sh` has its own lock and checks `link_ok` (2 MB within ten seconds) before
copying anything large. It retries every ten minutes; failures preserve the job.
Symbols upload on Linux with the existing private PostHog credentials, then
screenshots refresh status/marketing. UUID acknowledgements avoid repeated uploads.
Missing credentials or upload failures retain the queue. Inspect disk usage if
an outage lasts days; unacknowledged jobs are deliberately never dropped.
`touch <status-dir>/deferred-force-slow` forces this gate closed for a ship proof;
remove it afterwards. Logs: `<status-dir>/deferred.log` and each run's
`upload-symbols.log`, `deferred.log`, `lock.log`. The lock never covers these copies.

**Installing for the owner** (the lead, with the owner's OK, once): `infra/updates/install.sh build/Airc-Chromium.app`
on the Mac, in the build copy, installs `~/Applications/Airc.app`. It refuses an existing installation and a bundle
that isn't a dev-channel Chromium build. `AIRC_INSTALL_DIR=<dir>` installs elsewhere (update proofs).

**Proving loopback updates without touching the owner.** With signing path settings
exported on the Mac, run `infra/updates/prove-local.sh`. It compiles a tiny Sparkle
app with a unique bundle ID, an isolated home and its own ephemeral loopback port.
Both versions are Developer ID signed; the fixture uses the old app's ATS policy
so a successful delta install also qualifies the transition's HTTP enclosure.
It opens with `open -g`, records download/verification/install/relaunch, checks the
new build and signature, unregisters the installed fixture and quits. Capture
stdout (including HTTP GETs) and `build/local-feed-proof/result.log`, then delete
that scratch build. This tests Sparkle transport and installer, not Airc's UI.

API references: [Sparkle gentle reminders](https://sparkle-project.org/documentation/gentle-reminders/),
[updater API](https://sparkle-project.org/documentation/api-reference/Classes/SPUUpdater.html) and
[SPUUpdaterDelegate](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html)
(`updater:willInstallUpdateOnQuit:immediateInstallationBlock:`).

### Isolated signing-continuity fixture

`infra/release/test-updater/run.sh` also accepts `AIRC_PROOF_DIR`, `AIRC_PROOF_FROM_IDENTITY` and
`AIRC_PROOF_TO_IDENTITY` (both default to `-`). Set `AIRC_PROOF_FULL=1` to omit deltas and exercise full ZIP
downloads as used by the dev feed (the default also tests Sparkle deltas). With the signing keychain settings
exported, run it twice:

```sh
AIRC_PROOF_FULL=1 AIRC_PROOF_DIR="$PWD/build/adhoc-signed" AIRC_PROOF_FROM_IDENTITY=- \
  AIRC_PROOF_TO_IDENTITY="$AIRC_SIGN_IDENTITY" infra/release/test-updater/run.sh
AIRC_PROOF_FULL=1 AIRC_PROOF_DIR="$PWD/build/signed-signed" AIRC_PROOF_FROM_IDENTITY="$AIRC_SIGN_IDENTITY" \
  AIRC_PROOF_TO_IDENTITY="$AIRC_SIGN_IDENTITY" infra/release/test-updater/run.sh
```

Each uses a throwaway bundle identifier derived from the directory name, a loopback-only feed, and its own install
folder. Sparkle verifies EdDSA, installs N+1, and relaunches it; the runner checks the installed version, deep strict
signature and Developer ID requirement. This proves the Sparkle signature transitions, not preservation of the
owner's Keychain ACLs/TCC grants. Keep the logs and delete fixture apps, profiles and caches afterwards.


## Public release command and recovery

`com.aircbrowser.Airc` is permanent, not a configurable test default. `package.sh`
sets it only for its own freshly compiled public app. `--app` rejects wrong identity,
missing automatic checks/downloads, wrong public key, missing telemetry configuration,
and test metadata. Stable and Nightly use the same signed identity and EdDSA key.
The public telemetry project key is included; every smoke and updater fixture runs
with telemetry off. Public smoke also disables Sparkle checks through its scratch
launch preferences so it never queries a live feed.

From the Linux checkout:

```bash
scripts/release/release.sh                    # stable 0.1.0; discovers matching green evidence
scripts/release/release.sh --green-run ../status/runs/RUN
scripts/release/release.sh --channel nightly --green-run ../status/runs/RUN
scripts/release/upload.sh ../artifacts/release/stable/VERSION-BUILD --verify-only
# Publication is a separate explicit action:
scripts/release/upload.sh ../artifacts/release/stable/VERSION-BUILD --go
```

`--dry-run` still really signs, submits to Apple and staples both app and DMG, and
runs the quarantine, install and signed full/delta Sparkle tests. It never uploads.
Without matching green-suite evidence it marks the result unqualified; `--go`
refuses it. A green run covers the exact app/package/engine/build-script inputs;
release-only documentation/tool changes may follow it. No dirty working-tree files
are copied: the command exports committed HEAD by default. To freeze an earlier
green application revision, pass `--revision COMMIT --green-run STATUS_RUN`.
Only `scripts/release` and `docs/release-notes-beta.md` come from committed HEAD;
all other inputs come from COMMIT. The stage records both full revisions and
copies the green run's revision and step results into `evidence/`. The global build sequence spans
Stable and Nightly and reserves UTC minute build numbers even after failures.
Version defaults to 0.1.0 (`AIRC_RELEASE_VERSION` changes it intentionally).

Private `airc.env` beside the checkout supplies the signing variables documented
above. No password or EdDSA seed is transferred off the Mac. Public artifacts go to
`../artifacts/release/CHANNEL/VERSION-BUILD/`: `Airc-VERSION.dmg`, `Airc-VERSION.zip`,
optional signed deltas, `appcast.xml`, `latest.json`, `notes.md`, `notes.html`,
`SHA256SUMS`, and a checked file inventory `release.json`. Private evidence, plist,
signature metadata and dSYMs stay outside the upload allowlist. Notes are escaped
HTML rendered from `docs/release-notes-beta.md`; the source revision is appended.
`latest.json` has version, build, DMG `url`, sha256, size, minimumMacOS and channel.

The Mac job uses `nohup caffeinate -i -s`, so an SSH loss does not restart a notary
submission. Recovery: reconnect to the build Mac, read
`~/arcfork/work/launchprep/build/release-exit` and `build/release-worker.log`, then
copy `build/stable-stage/` into the already reserved Linux staging folder using
`scripts/mac.sh -w launchprep get`. Run `upload.sh STAGE --verify-only` before any
upload. Never start a second worker over a running job. On a failed step preserve
logs, clean that task's intermediates and rerun with a new build number. Below
15 GB free on the Mac the orchestrator refuses a big build. Successful transfer
removes its duplicate Mac artifacts, profiles and SwiftPM caches.

## Blob and homepage handoff

Use the owner's team via private `AIRC_VERCEL_SCOPE`, and the linked
`airc-homepage` project via `AIRC_VERCEL_PROJECT_DIR`. Do not commit account/team
IDs. `AIRC_BLOB_BASE_URL` is the public store origin, and `BLOB_READ_WRITE_TOKEN`
is private operator configuration, never a command-line argument or a public file.
The CLI is authenticated; public store creation is also guarded by `--go`:

```bash
# Once, after the staged candidate passes all gates:
scripts/release/upload.sh STAGE --go --create-store
# Under the hood (run only with the owner's publication authorization):
vercel --cwd "$AIRC_VERCEL_PROJECT_DIR" --scope "$AIRC_VERCEL_SCOPE" \
  blob create-store airc-releases --access public --yes --environment production
# Configure the returned public store origin and its write credential privately, then:
scripts/release/upload.sh STAGE --go
```

Immutable Blob pathnames are `releases/VERSION/BUILD/Airc-VERSION.dmg` and `.zip`,
with notes and deltas in the same folder. No random suffix and no overwrite.
Uploads resume only if existing remote bytes match the manifest. After every
immutable download hash matches, the uploader promotes `feeds/appcast.xml` and
`feeds/latest.json` (Stable) or `feeds/nightly-latest.json` (Nightly). Mutable
pointers cache for 60 seconds; old immutable payloads remain available. Feed
promotion merges current public entries, never the private dev feed. Full ZIPs
remain a fallback for clients too old for the retained delta sources.

**Homepage thread: merge this into `vercel.json`**, replacing `BLOB_ORIGIN` with
`https://STORE.public.blob.vercel-storage.com`. No DMG/ZIP belongs in the homepage
deployment. Artifact routes redirect directly to Blob (including range requests);
only the small feed/manifest are proxied. This is a handoff, not authorization to attach the domain or deploy.

```json
{
  "rewrites": [
    { "source": "/appcast.xml", "destination": "BLOB_ORIGIN/feeds/appcast.xml" },
    { "source": "/latest.json", "destination": "BLOB_ORIGIN/feeds/latest.json" },
    { "source": "/download", "destination": "/api/download" }
  ],
  "redirects": [
    { "source": "/releases/:path*", "destination": "BLOB_ORIGIN/releases/:path*", "permanent": true }
  ],
  "headers": [
    { "source": "/appcast.xml", "headers": [{ "key": "Cache-Control", "value": "public, max-age=60" }] },
    { "source": "/latest.json", "headers": [{ "key": "Cache-Control", "value": "public, max-age=60" }] },
    { "source": "/download", "headers": [{ "key": "Cache-Control", "value": "no-store" }] }
  ]
}
```

**`api/download.ts`** (Vercel Node function; set `AIRC_BLOB_BASE_URL` in the homepage
project, a public origin, not a secret):

```ts
export default async function handler(_req: unknown, res: any) {
  try {
    const base = process.env.AIRC_BLOB_BASE_URL!;
    const response = await fetch(`${base}/feeds/latest.json`, { cache: "no-store" });
    if (!response.ok) throw new Error("No qualified stable release");
    const latest = await response.json();
    const url = new URL(latest.url);
    if (url.origin !== "https://aircbrowser.com" ||
        !/^\/releases\/\d+\.\d+\.\d+\/\d{12}\/Airc-[\d.]+\.dmg$/.test(url.pathname))
      throw new Error("Invalid release URL");
    res.setHeader("Cache-Control", "no-store");
    // Download directly from Blob; do not stream a large DMG through a function.
    res.redirect(307, `${base}${url.pathname}`);
  } catch {
    res.status(503).send("The download is not available yet. Please try again shortly.");
  }
}
```

Homepage button: `/download`. Privacy page must explain default-on telemetry,
the opt-out and actual data collected. Once deployed, anonymously verify all
three public endpoints, the final DMG hash, ZIP byte-range requests, XML MIME type
and the stable/nightly filtering. Blob storage/transfer limits and billing belong
to the owner's chosen plan; review measured DMG/ZIP sizes before announcement.
Sources: [Vercel Blob CLI](https://vercel.com/docs/cli/blob),
[public storage](https://vercel.com/docs/vercel-blob/public-storage).

## Automatic public nightlies and delta retention

The configured 01:15 UTC cron entry invokes `infra/release/nightly.sh` instead of
`infra/nightly.sh`. It first runs the existing full nightly, then the same public
pipeline with `--channel nightly`, then `upload.sh --go`. Any failed gate stops it.
The daytime `infra/ship-loop.sh` remains unchanged and private. Credentials and
public storage configuration must be ready before enabling the schedule.

`deltas.py` uses Sparkle's BinaryDelta and signs each result with the same EdDSA
key. The Mac cache holds three acknowledged published apps per public/dev stream
and at most one pending candidate. Only successful publication acknowledges a
cache entry. A missing cache produces a full ZIP safely; following builds gain
deltas automatically. Pruning touches only these owned caches, never the engine
or the owner's app. Public feed retains four items per channel; dev retains five.
The existing test-updater proves signed N→N+1 full and delta installation and
relaunch with an isolated stable loopback feed, not the owner's app or profile.

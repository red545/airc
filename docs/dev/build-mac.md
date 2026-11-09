# The build Mac

Everything that needs macOS runs on one Mac that is on all the time: the Chromium engine build, the app builds, the
test suite and UI checks, signing, notarization, Sparkle signing and the dev update feed. The Linux box runs the
agents, cron, the ship loop, the status page and the release tooling, and reaches the Mac as the ssh alias `buildmac`
(`AIRC_MAC_HOST`, used by `scripts/mac.sh`, `infra/nightly.sh`, `infra/status.py`, `infra/updates/*` and
`scripts/release/*`).

Until now the build Mac was the owner's own laptop: when it was closed or away, every build, check and release
stopped. This page sets up a **dedicated** Mac (an M1 Max MacBook Pro with 32 GB is enough) as `buildmac`, proves it,
without repointing the old `mac` alias. Part 1 is for the owner at the Mac; parts 2 to 4 are for agents over ssh.

## Current routing (2026-11-09)

All new builds and tests target `buildmac`; `mac` is held and must not be used as a fallback.
Agent helpers, nightly, publishing, deferred uploads and status default to the dedicated host.
The engine owner publishes `status/buildmac-engine-ready` only after a successful strict apply and
release relink. App sources must match that marker's `engine/` tree. Nightly refuses a mismatch.
`infra/reconcile-engine.sh` performs the serialized relink and updates the marker.

The ship loop and scheduled nightly remain disabled until an isolated dry ship is green. Set
`AIRC_PUBLISH_HOLD=1` as an additional publication guard. This guard blocks metadata writes as well
as dev/public publishing. Do not remove it based on a successful compile or signing smoke alone.
The laptop's existing loopback feed and LaunchAgent remain intact until a signed scratch dev-feed
proof and a separately coordinated feed bridge are complete. `LOCAL_FEED` is configurable, with
`http://127.0.0.1:3483/appcast.xml` as its compatibility default; on the dedicated host it must be
changed to the verified tailnet feed before live publishing.

For a no-publication dry ship, use an empty private configuration file, a separate `AIRC_STATUS_DIR`,
`AIRC_MAC_HOST=buildmac AIRC_PREPARATION=1 AIRC_DEV_CHANNEL=0`, and
`AIRC_NIGHTLY_REMOTE=arcfork/setup/automation/run-<unique>` with `infra/nightly.sh --ship`.
Hold the normal ship lock around the dry run so its separate status directory cannot race a relink.
Preparation rejects active paths, skips deferred queues/status rendering and returns failure for any
failed step. UI lock timeouts are refusals, including the ship suite's cumulative timeout budget.

### Signed scratch dev-feed proof (only after a green dry ship)

Use a separately exported, tested dev-channel checkout on the dedicated Mac. Its bundle must name
its scratch HTTPS feed and the repository's existing Sparkle public key. Start a separately rooted
feed server and tailnet-only HTTPS Serve endpoint with distinct frontend/backend ports; do not
install or reconfigure the existing feed's LaunchAgent. Then, **on the Mac**, from that checkout:

```bash
source ~/arcfork/setup/signing/signing.env
export AIRC_UPDATE_FEED=https://<build-host-tailnet>:<scratch-https-port>/appcast.xml
export AIRC_SCRATCH_PUBLISH_ROOT="$HOME/arcfork/setup/automation/feed-<unique>"
bash infra/updates/publish-local.sh
```

The scratch server must serve `$AIRC_SCRATCH_PUBLISH_ROOT/feed`. The publisher verifies that root
with a temporary random health file before signing. Preparation, deltas and acknowledgments use
`$AIRC_SCRATCH_PUBLISH_ROOT/cache`; live feed/cache paths remain untouched. Symlink roots, paths
outside `setup/automation/feed-NAME`, and parent traversal are refused. The Linux `publish.sh`
coordinator rejects this scratch variable because its metadata paths belong to the live feed.
`AIRC_PUBLISH_HOLD=1` or preparation mode refuses publication even with a scratch root configured.

Retain source/tooling revisions, signed launch smoke, signature verification, served appcast and
archive checksums. Remove only this proof's server/Serve rule after its checks. Do not bridge the
owner's installed loopback client or enable publishing until the lead coordinates that cutover.

## 1. Owner checklist (at the Mac)

### Decisions

| | Decision | Recommendation |
|---|---|---|
| D1 | Which macOS user runs the builds | A new admin user `airc` that runs only Airc. If the Mac has old personal data, erase it first (System Settings → General → Transfer or Reset → Erase All Content and Settings). |
| D2 | Apple Account on that user | **None at first.** The suite's iCloud checks use a mock CloudKit database in a folder. The real iCloud test (docs/sync.md) needs a signed-in account: later, a **separate test Apple Account**, never the owner's own (see below). |
| D3 | FileVault | **On**, because the Mac holds the signing keys. Trade-off below. |
| D4 | Lid | **Open**, built-in display: it is the 120 Hz ProMotion Retina panel that users have, which a dummy plug can't give. |
| D5 | Signing | A new Developer ID certificate made on this Mac, a new notary API key, and the owner moves the Sparkle key by AirDrop (part 3). |
| D6 | Dev updates for the owner's laptop | The build Mac serves the dev feed on the tailnet; the owner's Airc follows it after one bridge update (part 4). |

**The Apple Account (D2).** Signing in with the owner's own account would put their iCloud Keychain, Photos,
Messages and Drive within reach of every agent and test, and the real iCloud test would write into their private
CloudKit database. A separate test Apple Account (free, with its own phone number for two-factor) keeps all of that
apart. Its costs: one more account to keep; Find My and Activation Lock then tie the Mac to that account, so keep its
password safe; iCloud Keychain needs two-factor and a login password, which the `airc` user has. The Xcode download
does not need an account on the Mac: sign in to developer.apple.com in Safari only.

**FileVault (D3), plainly.** With FileVault on, macOS turns automatic login off. After any **unplanned** restart (a
crash, a dead battery, a forced macOS update) the Mac waits at the unlock screen until someone types the password
at it. Tailscale and SSH don't start before login, so nothing can reach it from outside, and 24/7 isn't guaranteed.
On macOS 26 on Apple silicon, the disk can also be unlocked over SSH after a restart, but only from a device on the
same home network (Remote Login must be on beforehand; test it once). **Planned** restarts use
`sudo fdesetup authrestart`, which skips the unlock screen once. A MacBook's own battery carries it through power
cuts, so unplanned restarts should be rare. With FileVault **off**, the Mac would log in by itself after any restart,
but a thief would get the Developer ID key and the Sparkle key, enough to ship malware to every Airc user as an
update. While the new Mac is waiting at the unlock screen, the old Mac stays as the fallback.

### Steps

1. **macOS.** The latest macOS 26 (Tahoe) update; the old build Mac runs 26.6.2. Move to a new major version only on
   purpose, once the toolchain has been tested on it, never through an automatic update. Set the computer name to
   `buildmac` (General → Sharing).
2. **Apple Intelligence.** System Settings → Apple Intelligence & Siri → on. The device language and the Siri
   language must be the same supported language (English (US), like the old build Mac). It works in the EU, but not
   in mainland China. It downloads the on-device model (about 7 GB). The AI checks run the real on-device model when
   it's available.
3. **Xcode 27.2 (build 27B52).** Download the .xip from developer.apple.com/download (signed in in Safari), expand
   it, move it to /Applications, open it once, accept the licence and install the macOS components it offers. Then
   in Terminal run `xcode-select --install` (Command Line Tools) and `sudo DevToolsSecurity -enable`, so Instruments
   and lldb never ask for a password.
4. **Tailscale.** Install the Standalone app from tailscale.com/download (not the App Store version), log in to the
   same tailnet, turn on "Start on login", and in the admin console name the machine `buildmac` and **disable key
   expiry** for it (otherwise it drops off the tailnet after 180 days).
5. **SSH: macOS Remote Login, not Tailscale SSH.** On macOS, Tailscale SSH needs the separate command-line-only
   `tailscaled` build, while Remote Login works with the normal app and the existing scripts and is what macOS 26's
   FileVault unlock over SSH uses. General → Sharing → Remote Login: on, allow only `airc`. Add the Linux box's
   public key (the agent gives it to you):

   ```sh
   mkdir -p ~/.ssh && chmod 700 ~/.ssh
   echo '<public key from the agent>' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
   ```

   Also turn on **Screen Sharing** for `airc`, so you can answer the first permission prompts from your laptop
   (Finder → Go → Connect to Server → `vnc://buildmac`).
6. **Never sleep.** In Terminal:

   ```sh
   sudo pmset -a sleep 0 displaysleep 0 disksleep 0 powernap 0 standby 0 ttyskeepawake 1 tcpkeepalive 1
   sudo pmset -c womp 1 lowpowermode 0
   sudo pmset -b lowpowermode 1
   ```

   A MacBook has no "start up after a power failure" setting: its battery keeps it running through a power cut, and
   it starts by itself when power returns after the battery ran out (then FileVault asks for the password).
7. **Display, lock and screen saver.** Lock Screen: screen saver never, display off never (battery and power
   adapter), require password after screen saver or display off: never. Privacy & Security → Advanced: no automatic
   log-out. Desktop & Dock: no hot corners, Stage Manager off, "Automatically rearrange Spaces" off. Turn the
   brightness all the way down and leave the lid open. UI checks need an unlocked, awake display with the app on the
   active Space.
8. **Nothing pops up over the tests.** Turn on Do Not Disturb from Control Center (it stays on). General → Software
   Update → Automatic Updates: download only, install nothing automatically (no macOS, app or security-response
   installs, which can restart the Mac); agents tell you when updates are waiting and you install them in a planned
   restart. App Store: no automatic updates. Siri off unless needed, Screen Time off, Time Machine off. Spotlight →
   Search Privacy: add the `arcfork` folder in the `airc` home (the Chromium tree has over a million files). Privacy
   & Security → "Allow accessories to connect": automatically when unlocked (so a USB-C adapter never waits for a
   click).
9. **Battery.** Battery → Battery Health → Optimized Battery Charging: on. macOS learns it is always plugged in and
   holds the charge lower. Optional: AlDente to cap it at about 80%. Put the Mac on a hard surface with free air at
   the back; a Chromium build runs the fans for hours. Agents check the battery condition (`system_profiler
   SPPowerDataType`) each week; if the case ever lifts or the trackpad feels stiff, unplug it and have it serviced.
10. **Network.** Wired Ethernet through a USB-C adapter if the router is near; otherwise Wi-Fi 6. Upload speed
    matters: public nightlies and releases upload their DMG, update ZIP and symbols from the Mac (about 0.5–1.5 GB
    each). 20 Mbit/s up works; 50+ is better. Agents measure it with `networkQuality`.
11. **Disk.** Airc needs about 200 GB on top of macOS (part 2). **Minimum: 300 GB free** after macOS and Xcode are
    installed, which means a 512 GB SSD is tight and 1 TB is comfortable.

## 2. Setup over SSH (agents)

The Linux box gets a separate key and a temporary alias for the new Mac, so access to it can be revoked on its own and
nothing that uses `mac` changes before the cutover:

```
Host buildmac
  HostName <the Mac's tailnet address>
  User airc
  IdentityFile ~/.ssh/id_ed25519_buildmac
  IdentitiesOnly yes
  ServerAliveInterval 30
  ServerAliveCountMax 6
```

Run everything as `AIRC_MAC_HOST=buildmac …`. Same rules as on the old Mac: no sudo, no Homebrew, tools as pinned
release downloads under `~/arcfork/tools/`.

| Step | How | Time |
|---|---|---|
| Check the base | `sw_vers`, `xcodebuild -version`, `xcode-select -p`, `pmset -g`, `fdesetup status`, free disk, `networkQuality` | 5 min |
| Metal toolchain | `xcodebuild -downloadComponent MetalToolchain` (ANGLE needs it) | 5–10 min |
| Quiet defaults | `defaults write com.apple.CrashReporter DialogType none` (no "quit unexpectedly" dialogs over the tests) | 1 min |
| depot_tools | `git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git ~/arcfork/depot_tools` | 5 min |
| Sparkle, libwebp, dev feed | `scripts/release/setup-sparkle.sh` (pinned 2.10.1), libwebp's release binaries for `cwebp`, `infra/updates/local-feed.sh` | 15 min |
| Chromium checkout | a fresh `gclient sync --no-history` of `CHROMIUM_VERSION` (below) | 1–3 h |
| First full engine build | `engine/build.sh --start` (out/AircRelease), timed | about 4 h |
| Package tests | `swift test` for each package in `packages/` | 2–5 min |
| App build and UI checks | `scripts/build-app.sh --snapshots build/snapshots --snapshot-engines chromium`, under the new Mac's own `~/arcfork/.ui-check.lock` | 40–60 min |
| Code-sign clone prune | a LaunchAgent on the Mac, hourly (below) | 10 min |
| Status page | `infra/status.py` follows `AIRC_MAC_HOST`; add the battery condition and uptime to the Mac row | 30 min |

**Chromium checkout.** The same steps that made the old Mac's checkout, with `.gclient` solution `src`
(`https://chromium.googlesource.com/chromium/src.git`, unmanaged, `checkout_pgo_profiles: False`):

```sh
export PATH=$HOME/arcfork/depot_tools:$PATH DEPOT_TOOLS_METRICS=0
cd ~/arcfork/chromium
caffeinate -s gclient sync --no-history -j 10 --revision src@refs/tags/$VERSION > ~/arcfork/fetch-chromium.log 2>&1
echo "EXIT $?" >> ~/arcfork/fetch-chromium.log
```

`engine/build.sh` starts only once that log ends in `EXIT 0`. The download is about 20–25 GB: about 1 h at 100
Mbit/s, about 3 h at 3 MB/s, plus unpacking and hooks. Copying the old Mac's tree over the home network would take
30–45 min, but it loads the old Mac and needs ssh between the two Macs. Relaying it through the Linux box is too slow
(1–5 MB/s measured, so 2–9 h).

**Engine build time.** On the old build Mac (Apple M5, 10 cores, `-j 8`) a clean out/AircRelease took 3 h 07 min for
57,750 steps. An M1 Max has about three quarters of that throughput, so expect 3.5–4.5 h. A dedicated Mac can use
`AIRC_BUILD_JOBS=10`.

**The prune job.** Every launch of a freshly built app leaves a code-sign clone in the user's temporary folder (319 GB
of them filled the old Mac). Prune them on the Mac itself, so it doesn't depend on the Linux cron. A LaunchAgent with
`StartInterval` 3600 runs:

```sh
d=$(getconf DARWIN_USER_CACHE_DIR)
find "${d%C/}X" -mindepth 2 -maxdepth 2 -type d -name 'code_sign_clone.*' -mmin +60 -print0 | xargs -0 rm -rf
```

**Disk budget.**

| What | Size |
|---|---|
| Chromium source (checkout, no out dirs) | 31 GB |
| out/AircRelease (`symbol_level = 0`) | 7–10 GB |
| out/Airc (DCHECK build, optional) | about 15 GB |
| Agent work folders (`~/arcfork/work/*`) | 20–40 GB |
| Ship and nightly tree, dev feed, update caches | about 15 GB |
| A release packaging run | about 15 GB |
| Code-sign clones between prunes, SwiftPM and other caches | about 20 GB |
| Apple Intelligence model | about 7 GB |
| Xcode and the Metal toolchain | about 15 GB |
| Free-space floor for builds | 15 GB |
| **Total** | **about 200 GB** |

## 3. Secrets and signing

Nothing secret goes through chat, the repo or a command line. Secrets travel only by T3's `request_secret` (file
delivery) or by the owner's own hands at the Mac. Signing material lives in `~/arcfork/secrets/` on the Mac (mode 700)
and in a dedicated keychain.

- **The signing keychain.** An agent creates a new dedicated keychain with a random password written straight to a
  mode-600 file (never printed), adds it to the user's search list and grants `codesign` access (partition list).
  The operator's private `airc.env` on the Linux box gets the new keychain and password-file paths, but never the
  password itself.
- **Developer ID Application certificate: a new one for this Mac.** An agent makes the private key and a certificate
  request on the Mac; the key never leaves it. The owner (as Account Holder) uploads the request at
  developer.apple.com → Certificates → Developer ID Application and gives back the downloaded certificate (public).
  Same team, so the same designated requirement (`anchor apple generic`, the Developer ID markers and the team in the
  leaf's OU), so installed builds accept updates, and Keychain items and privacy grants carry over. **Prove it**
  before the cutover: `codesign -d -r-` on old- and new-signed builds must print the same requirement, and the
  isolated signing-continuity fixture (docs/release.md) must update an old-signed build to a new-signed one. The
  owner also regenerates the Developer ID provisioning profile (iCloud, later passkeys) with the new certificate
  selected. Both certificates can stay valid for installed-copy continuity. The held laptop does not sign builds.
- **Notarization: a new App Store Connect API key** (Users and Access → Integrations → Team Keys, role Developer),
  delivered by `request_secret`. An agent stores it with `xcrun notarytool store-credentials <profile> --key … --key-id
  … --issuer … --keychain <signing keychain>` and deletes the file. Each Mac then has its own key, revocable on its
  own.
- **The Sparkle EdDSA key: the owner's decision.** All installed copies of Airc trust exactly one public key, so this
  key can't be re-issued per Mac.
  - **Move it (recommended).** The owner AirDrops the key file from the old Mac's `~/arcfork/secrets/` to the build
    Mac (or uses a USB stick, then wipes it). An agent moves it into place (mode 600) and checks its public key
    against `infra/release/sparkle-public-key.txt`. It never passes through the Linux box, chat or the repo.
    Keep one offline backup (a password manager): a lost key means no update can ever reach an installed copy again.
  - If the key has not reached the dedicated Mac, keep publication held. Do not route signing back to the laptop.

## 4. Cutover

1. **Hold the laptop.** Keep `mac` idle: no builds, checks, relinks or signing. Preserve its existing feed and
   installed app. Do not repoint its SSH alias or work around the SSH hold.
2. **The proof: a dry ship run on the new Mac.** Run it from an immutable scratch clone of a committed main
   revision. Never edit the checkout while its shell scripts are running:
   `AIRC_MAC_HOST=buildmac AIRC_STATUS_DIR=<scratch> AIRC_UPDATES_CONFIG=<empty file>
   AIRC_PREPARATION=1 AIRC_DEV_CHANNEL=0 AIRC_NIGHTLY_REMOTE=arcfork/setup/automation/run-<unique>
   infra/nightly.sh --ship`. Hold the normal ship lock around this isolated run. It must not start deferred
   uploads or render live status. All package tests, both bundles and every WebKit and Chromium
   snapshot check must be green. Full preparation uses the normal UI lock with a strict five-minute wait per
   launch, not a quiet window or a cumulative suite budget. `FAIL-ENV` assertions, missing evidence and incomplete
   suites prevent qualification even if the regular UI classifier's aggregate says PASS. Do not enable camera,
   microphone or screen-recording checks. Then one signed
   publish to a scratch feed, the designated-requirement proof from part 3 and a fresh launch smoke.
3. **The dev feed on the tailnet.** The build Mac serves its loopback feed through `tailscale serve --bg
   --https=8445 http://127.0.0.1:3483`. That makes it HTTPS on the tailnet name, never Funnel, and serves only the
   dev channel's signed files. Sparkle checks every EdDSA signature as before. The dev feed URL becomes a setting in
   the operator's `airc.env`, with today's loopback URL as the default until the cutover. **The bridge:** after the
   cutover, the old Mac's loopback feed gets the new feed's appcast once (its downloads point to the tailnet feed),
   so the owner's Airc installs a build that reads the tailnet feed from then on. The lead coordinates this feed
   maintenance separately; it does not authorize agents to bypass the laptop's SSH hold. Updates then reach the owner's
   laptop anywhere it's on the tailnet, straight from the build Mac.
4. **The switch**, at a quiet moment the lead picks: no ship run, release staging, relink or quiet window in
   progress.
   - Keep `mac` held. Set `AIRC_MAC_HOST=buildmac` in private automation configuration.
   - `airc.env`: the new signing identity, keychain and password-file paths, and the tailnet dev feed URL.
   - Crontab: drop the ssh prune line; the build Mac's LaunchAgent does it.
   - Owner installation telemetry uses `AIRC_OWNER_MAC_HOST` only when explicitly configured; otherwise it
     retains cached results without contacting any Mac.
   - `briefs/common.md`: the build Mac is now dedicated. Rules that existed only because it was the owner's laptop
     can relax. The no-camera, no-microphone and no-screen-capture rules stay: nobody is there to answer a prompt.
5. **Rollback.** Stop new automation and restore the saved configuration with publishing held. Do not route
   builds back to the laptop: that requires a new explicit owner instruction lifting its hold. Preserve the
   existing feed and installed app while investigating the dedicated host.

## 5. Running it

- **Planned restarts** (macOS updates): `sudo fdesetup authrestart` by the owner over SSH, then an agent checks that
  the `airc` session is back, the display is awake (`caffeinate -u -t 2`) and the dev feed answers.
- **After an unplanned restart** the Mac is offline until it's unlocked (part 1, D3). Agents treat an ssh timeout as
  "offline", not a failure, retry every 5 minutes, and tell the lead.
- **Weekly**: free disk, battery condition, waiting software updates and the age of the oldest work folder go on the
  status page.

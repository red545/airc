# Framework build variants

`engine/build.sh --start` defaults to `--variant release`: optimized, noncomponent,
`dcheck_always_on = false`, output `out/AircRelease`. It runs under `caffeinate -i -s`
in the `airc-engine` screen session, logging to `~/arcfork/airc-engine-release.log`.
It does not replace the existing developer framework. A successful build ends in
`EXIT 0`; a started build is not yet a usable release.

`engine/build.sh --run --variant dev` keeps DCHECKs enabled in the existing
`out/Airc` directory. This avoids allocating a third output tree. Both variants
are optimized (`is_debug = false`); assertions are the distinction. The normal
workflow builds one at a time. During the initial release rebuild, incremental
qualification can use two jobs in `out/Airc`, leaving six for the release build
(`AIRC_BUILD_JOBS`). Each output has its own build lock. Both share source: sync
changes before building, and run the release target again after the final source
change to ensure that an earlier object did not miss it.

The app bundler already accepts `CHROMIUM_OUT`; it defaults to `out/Airc` for
compatibility. **Owner packages must explicitly select the release output:**

```bash
CHROMIUM_OUT="$HOME/arcfork/chromium/src/out/AircRelease" scripts/build-app.sh
```

This also selects the framework and helpers embedded in `Airc-Chromium.app`.
Do not copy a single framework binary between variants. Keep the whole framework
and its matching helpers/resources together. Agent qualification uses:

```bash
CHROMIUM_OUT="$HOME/arcfork/chromium/src/out/Airc" engine/host/build.sh build/dialog-host
```

Disabling DCHECKs is packaging policy, not a fix for invalid modal ownership.
Dialog qualification must pass with the developer framework.

## Official variant (PGO + ThinLTO)

**This is the default engine** for `engine/build.sh`, `scripts/build-app.sh`, `scripts/release/package.sh`, marketing
and social frames (artifacts/engineofficial: 156.0.8078.109, 0 correctness regressions, launch and memory no worse,
pulse page CPU −23 %). Relinks go to `out/AircOfficial`; `--variant release` still builds the non-official `out/AircRelease`.

`engine/build.sh --run --variant official` builds `out/AircOfficial` with the args in
`engine/args/official.gn`: `is_official_build`, `chrome_pgo_phase = 2`, `use_thin_lto`,
zero-initialized stack variables, and otherwise the release variant's choices (symbols 0,
branding, codecs, Widevine not bundled, non-component). Measured on 156.0.8078.88
(artifacts/enginepgo): visible-page CPU −21 to −23 %, framework 452 → 252 MB.

It needs Chromium's PGO profile. Set `"checkout_pgo_profiles": True` in `.gclient`
`custom_vars`, then in `src` run the two hooks that `build.sh` prints when the profile is
missing (`tools/update_pgo_profiles.py … update` and V8's `download_profiles.py`). **Run them
again after every Chromium version bump**: `chrome/build/mac-arm.pgo.txt` pins one profile per
version, and a stale profile builds but loses most of the gain.

Cost: an engine/core change relinks the whole framework with ThinLTO (the cache in
`out/AircOfficial/thinlto-cache` makes small changes a few minutes; a cold link is
15–30 min); a Chromium version bump is a cold full build (~40k steps). The output with its
ThinLTO cache takes ~12 GiB.

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

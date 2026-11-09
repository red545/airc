# Blocking filter bridge

Airc uses pinned adblock-rust 0.13.5 behind `../airc_blocking_ffi.h`. The bridge
has explicit byte lengths, owned result buffers and a matching free function;
no Rust container or reference layout crosses the C boundary. Callers own handle
lifetime and must never destroy a handle while another call is using it.

`BUILD.gn` builds an rlib with Chromium's compiler, standard library, allocator
and linker settings. The private `third_party` graph is generated with Chromium
156's gnrt, then its labels, crate metadata and target names are namespaced. It
does not replace or upgrade Chromium's own crate graph. The two ICU data crates
include `../data` in their gnrt input roots. FlatBuffers uses its stable iterator
implementation: its build script only enables nightly TrustedLen, so GN omits
that script instead of relaxing Chromium’s unstable-feature restrictions. Crate source bytes and package
checksums are preserved. To regenerate, first build Chromium 156's `gnrt`, then
run `python3 generate-gn.py CHROMIUM_SOURCE GNRT_BINARY NEW_WORK_DIRECTORY`.
The new work directory holds an isolated overlay; generation is offline and
cannot overwrite Chromium's crate graph. Review its `generated/*/*/BUILD.gn`
files and copy only those files into this directory's `third_party` tree.
Run the bridge target with Chromium's release configuration after regenerating. `blocking_bridge_test` exercises the ABI, request type,
party/exception matching, parameter removal, CSP and ordinary cosmetic selectors.

The standalone WebKit app uses `build-standalone.sh OUTPUT_DIRECTORY`. It builds
the same bridge offline from Cargo.lock and vendored sources with Rust 1.98 or
newer (the supported release pipeline uses Chromium's pinned compiler). It also
builds `export-rules` for CC BY-SA release artifacts. **Do not link that Cargo
static archive into the Chromium framework or Chromium app:** the GN target
already provides the bridge and runtime, and exports the C ABI for Swift.

The `measure-heap` feature is only for the isolated feasibility harness. Never
enable it in GN: Chromium owns the process allocator. Runtime matching uses the
flat `AircBlockingDecision`; JSON is for diagnostics and infrequent cosmetic or
conversion operations. A caller must handle the returned rewrite and CSP fields,
not only the blocked flag. No scriptlet or redirect resource library is loaded.

The exact crate versions, declared licenses and checksums are in
`DEPENDENCIES.json`. Full notices are in `THIRD-PARTY-NOTICES.md` and `licenses/`.
The MPL-2.0 adblock source remains under its original license. Public-suffix data
retains MPL-2.0 provenance alongside its crate's MIT notice; Unicode data retains
its Unicode notices. Chromium's GN template license is in `third_party/LICENSE`.
See `docs/user/blocking.md` for user controls, list attribution and engine limits.

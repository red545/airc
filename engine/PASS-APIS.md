# Engine APIs: Save Page and tab previews

This pass adds `AircTab (Exports)` in `core/public/Airc.h`. Calls are main-thread
only, after engine startup. Both completions run once, asynchronously on main.
No app sources are changed. One pinned upstream rename-error hook is added.

## Save Page

`canSavePage` checks the tab itself, including when it is in the background:
live renderer, Chromium's savable MIME and URL rules, the profile's download
restriction, the file-selection policy and `CONTENT_RESTRICTION_SAVE`.
Chromium 156 also lists chrome/devtools schemes as savable; the host API
explicitly excludes chrome, chrome-untrusted and devtools pages as requested.
Thus this is Chromium's eligibility plus the host document-export restriction.
PDF viewers and internal pages are unsupported by this API. Chrome's separate
PDF-download fallback is deliberately not invoked.

```swift
if tab.canSavePage {
    tab.savePage(to: path, format: .complete) { error in
        // nil means Chromium finished the save package.
    }
}
```

`AircSavePageFormat` has stable raw values matching Chromium's SavePageType:
HTML = 0, Complete = 1, MHTML = 2 (Swift `.html`, `.complete`, `.mhtml`). HTML
saves only the document; Complete serializes the document and resources into a
sibling `<basename>_files` directory; MHTML writes a single archive. Complete
may omit the directory when no resources require it. Chromium retains its
normal best-effort handling of unavailable subresources.

Pass an absolute destination chosen by the app's save panel. The API calls
`WebContents::SavePage`, bypassing Chromium's filename dialog. A per-tab observer
matches the resulting SavePackage download by WebContents and destination. It
reports completion only after the download reaches COMPLETE; this is not a
fire-and-forget command. Normal download policy and history still apply.

Runtime qualification exposed a Chromium error: SaveFileManager ignored
`SaveFile::Rename` failures and unconditionally scheduled SavePackage::Finish.
Patch 028 replaces that one call with `airc::RenameSaveFile` (plus an include).
The core wrapper posts Cancel(false) for the matching package ID on failure,
before the existing Finish task. Without it, even a regular file blocking the
destination's parent path reported success. No public download observer exposes
the ignored rename result; this is why a small upstream seam is necessary.
The strict series now pins 61 upstream files across 28 patches.

Errors are `notSavable`, `busy`, `cancelled`, or `failed:<short reason>`.
One save at a time is accepted per tab. Navigation, destruction and manager
shutdown retire the pending callback. Explicit user download cancellation
reports `cancelled`. Chromium uses the same USER_SHUTDOWN download reason for
internal SavePackage cancellation and disk errors, so that case reports
`failed:save cancelled or write failure`; it cannot be distinguished through
public download observers. Write/rename failures are not reported as success. A cancelled or failed Complete save can
leave a partial HTML/resource set; the API does not recursively remove a
host-chosen destination that may already contain user files.

The existing app-owned SavePage.swift defines PageSaveFormat `.complete`,
`.htmlOnly`, `.singleFile` and engine-name strings `complete`, `html`, `mhtml`;
it does **not** yet reference an engine enum or adopt EnginePageSaving. Map
those cases to `.complete`, `.html`, `.mhtml`, respectively, in the app adapter.
The engine cannot make its existing Chrome-command fallback use the host panel
without that app wiring. SavePage.swift was read, not edited or committed.

## Tab previews

```swift
tab.snapshot(withMaxSize: CGSize(width: 640, height: 400)) { image in
    // Cache the last non-nil image in the app for hidden/discarded tabs.
}
```

The size is a pixel bounding box, preserving aspect ratio and never upscaling;
each dimension is capped at 4096. Invalid or subpixel dimensions return nil.
`CopyFromSurface` copies the current compositor surface, with a 500 ms Viz
copy timeout. Resizing runs on Chromium's worker pool; only the small NSImage
conversion and completion run on main. There is no periodic capture, forced
repaint, tab activation, WasShown call, screen capture, or capture permission.

Unloaded/discarded tabs, crashed renderers, missing surfaces and copy errors
return nil. A hidden/background tab can return its last frame **only while
Chromium retains a copyable surface**; it can be stale, and a suspended or
evicted surface can fail. The app must cache the last useful snapshot itself.
The API does not promise to obtain a fresh frame from a hidden tab.

## Verification

`engine/host/tests/apis.mm` is a separate engine host, using only loopback
fixture content. `apis.mjs` launches it with `open -g`, an isolated profile and
mock keychain. It checks all three output files and reopens each, checks the
Complete resource, busy/write-error/unsupported cases, measures callbacks,
checks snapshot dimensions and contrasting pixels, and tests hidden/discarded
snapshots and explicit download cancellation. MHTML disables main-world script
execution, so reopening it is checked by the fixture title and rendered pixels;
HTML and Complete additionally check DOM text. It never invokes camera, microphone or desktop capture.

From a synced work copy on the build Mac, after the incremental release build:

```sh
CHROMIUM_OUT="$HOME/arcfork/chromium/src/out/AircRelease" \
  AIRC_HOST_SOURCE="$PWD/engine/host/tests/apis.mm" \
  engine/host/build.sh build/apis-host
node engine/host/tests/apis.mjs build/apis-host/AircHost.app build/apis-results
```

The coordinator must hold its ship lock throughout `apis-build.py`, which
invokes `engine/build.sh --run --variant release`, requires at least 14 GB
free and stops its own build process group if free space drops below 12 GB.
It never touches `out/Airc`. Use fresh test output directories and remove
them after retrieving evidence.

Compile-only preflight (does not mutate the Chromium checkout):

```sh
python3 engine/host/tests/apis-compile.py
xcrun clang++ -std=c++20 -fobjc-arc -Werror -fsyntax-only \
  -Iengine/core/public engine/host/tests/apis.mm
xcrun swiftc -typecheck -warnings-as-errors -Iengine/core/public \
  engine/host/tests/apis.swift
```

## Qualified results

The final release host passed all assertions and exited without native crash
markers. Initial test-harness readiness/evaluation assumptions were corrected;
the final runner uses Airc's explicit evaluation result callback and does not
require an MHTML archive to itself be savable. A nonexistent parent directory
is created by Chromium, so the write-error fixture uses a regular file blocking
the parent directory instead.

| Operation | Final fixture result | Callback time |
| --- | --- | --- |
| HTML | 189 bytes; reopened DOM matches | 30.83 ms |
| Complete | 360-byte HTML plus art.svg in complete_files; reopened DOM matches | 14.89 ms |
| MHTML | 1,293-byte archive; reopened title and red/blue pixels match | 105.05 ms |
| Visible snapshot | Nonblank 640 × 400 pixels | 8.90 ms |
| Hidden snapshot | nil; existing surface copy timed out | 502.48 ms |
| Discarded snapshot | nil | 5.75 ms |

These are single-run fixture latencies, not performance percentiles. Busy,
write-error, unsupported chrome://version and explicit cancellation assertions
also pass. Hidden capture is conditional on a retained surface; this run
confirms the app needs its own cached image.

All four incremental release builds passed under the coordinator ship lock,
released immediately after each build: 43 steps / 64.31 s, 5 steps / 38.18 s,
4 steps / 32.77 s, and 4 steps / 33.49 s. The last also removes detached
temporary files after a failed rename. No out/Airc build ran.
The implementation compile preflight, final Swift/Objective-C import checks and
strict apply/repeat/drift tests pass. Evidence and final disk/cleanup details
are in the private engineapis report; test bundles are not committed.

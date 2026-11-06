# Pass 12: app integration APIs

Changes are confined to `engine/`. `app-pass12.patch` is an unapplied integration
patch against the app sources read during this pass. It forwards lifecycle
signals, removes Chromium's removal/Stay heuristics, opts into same-tab Peek,
and exposes picker and explicit-host PiP entry points. The picker opt-in remains
false until the app installs its UI. The app agent owns that UI and Little Arc's
retained-player lifetime.

## APIs and contracts

- `tabDidCancelClose:` reports Stay on a pending `-[AircTab close]`. It is not
  emitted for a cancelled ordinary navigation. `tabDidCloseForHost:` reports
  deletion after the host close path; `tabWillClose:` retains page-initiated
  semantics. Completion is a tab-removal notification, before WebContents
  destruction: defer app/tab-strip mutations to the next main-loop turn. Forced
  `closeNow` also completes through this path, but does not promise a user's
  approval or indefinitely running unload handlers. Shutdown/window teardown
  retains its existing separate lifecycle.
- Implement `tabWantsPasswordSuggestions:` returning YES to replace Chromium's
  password popup with host rows. `tab:didShowAutofillSuggestions:` supplies
  username `label`, site `sublabel`, `type=password` and an opaque integer string
  `index`. Pass that integer to `acceptAutofillSuggestion:`; do **not** use the
  array offset. Handles are never reused within the tab. Duplicate credentials
  are collapsed; unrelated cross-domain credentials, headings, actions and
  submenus are excluded. Password values never cross the Objective-C API.
  Chromium's original delegate performs filling and retains its normal
  authentication/validation. This is a password picker, not a replacement for
  address/card/passkey UI.
- `hideAutofillSuggestions` withdraws host password rows. An empty row callback
  dismisses the picker. Navigation, frame deletion, field change, tab hiding,
  Chromium's HideSuggestions and replacement invalidate handles. Acceptance
  checks frame/field identity and a 500 ms anti-accidental-selection interval;
  NO means stale, premature or unavailable. Hide when dismissing the app picker.
  Keep page-field focus while interacting with the picker. Native popup layout
  and keyboard behavior have not been visually qualified.
- `engine:routeLink:opener:` now also sees `disposition=current_tab` before a
  renderer-initiated, user-gesture, primary-frame cross-site HTTP(S) link request.
  Sites use Chromium's schemeful registrable-domain logic (including private
  registries), not the app's last-two-label heuristic. YES cancels without an
  error page; NO proceeds. Host navigations, same-site links, same-document
  changes, subframes, POSTs and redirects are not rerouted. Never mutate the
  source's tab strip synchronously from the policy callback. This reuses the
  existing throttle registration; no new navigation hook patch is required.
- `enterPictureInPictureForHost:` is a trusted native action, with a completion
  `(route, opened)`. It uses the existing document-identity-fenced native PiP
  path with the host action's current time. `element/YES` confirms video entry;
  `session/NO` dispatches to a site's asynchronous MediaSession handler and
  requires the existing PiP state callback for eventual entry. `none/NO` means
  unavailable. It is **not** an automatic background policy: do not call it on
  timers or tab switches. Existing profile/site automatic PiP policies are
  unchanged. Normal renderer permission/disablePictureInPicture checks apply.

## Little Arc lifetime

Check the app's PiP settings/site policy and active playback before offering the
mini player on close. Return NO from `windowShouldClose` while requesting host PiP. On confirmed
entry, hide the native window and retain the AircWindow/AircTab; on PiP exit,
close or restore them according to app policy. Destroying the WebContents or
closing its owning engine window destroys playback. A failed or site-delegated
entry must resolve normally instead of leaving an invisible orphan. This pass
adds and tests the entry point; it does not implement the app mini-player UI.

## Call fallback feasibility (SB-55 remains partial)

A main-frame `<video srcObject=MediaStream>` can enter ordinary video PiP through
the explicit-host path, including while its owning native window is hidden. The
probe uses fake camera and microphone capture with scratch-only mocked system
permission; it stops both tracks before quitting.
Only the selected video is shown. This does not establish automatic call PiP,
a multi-camera layout, or microphone control for arbitrary call sites.

Chromium 156's `MediaSessionImpl::CanEnterBrowserInitiatedAutomaticPictureInPicture`
requires one eligible playing main-frame player and rejects active camera/mic
use. Its normal call auto-PiP path uses the site's MediaSession action handler.
Document PiP is where a cooperating site can place its layout and controls.

A generic engine cannot enumerate JavaScript-owned local microphone tracks that
are not attached to DOM media elements, nor infer which remote tile is the active
speaker. `AircTab.muted` mutes playback, not the outgoing microphone. Stopping
capture is not reversible mute. MediaSession microphone/hang-up actions work
only when the page supplies those handlers. Exposing a generic “mute” button
without those guarantees would misrepresent call privacy.

A reliable future fallback needs renderer-level capture-session/track control
and a specified tile compositor, or site adapters. A Leave button can already
call `close` and honor beforeunload, with this pass's explicit Stay/completion
signals. No incomplete `enterCallPictureInPictureWithControls:` API is exposed.

## Reproduce

On the build Mac, from the synced engine work copy, with only one engine build
at a time:

```sh
engine/build.sh --start --variant dev
# After EXIT 0:
caffeinate -i -s engine/host/pass12.sh dev build/pass12-dev-new
engine/build.sh --start --variant release
# After EXIT 0:
caffeinate -i -s engine/host/pass12.sh release build/pass12-release-new
```

Both builds use the `airc-engine` screen session and existing incremental output
folders. The release variant is rebuilt last because the owner's app links it.
The host uses two synthetic profiles, `open -g`, fake fixture credentials, and
quits each process. It never unlocks or activates the owner's desktop.

## Verification

The private evidence directory is `artifacts/engine/pass12/`. The final host
runs are `dev-qualified/` and `release-qualified/` (frameworks DCHECK-on and
DCHECK-off respectively). These are state assertions, not visual qualification.

The `pass12` scenario asserts:

- Two imported saved logins produce exactly the intended username choices.
  Selecting Bob fills the expected synthetic secret. Reusing the handle fails.
  The second profile's password field remains empty.
- A user-gesture same-tab cross-site link produces one `current_tab` policy
  callback, leaves the opener at its old URL and opens the policy destination
  under the chosen profile. A same-site link navigates without another callback.
- A host close creates a real child-modal beforeunload dialog. Cancel invokes
  exactly one Stay callback and keeps the page; a second close followed by the
  native Accept handler closes it and invokes one host completion callback.
- Explicit host PiP reports `element/YES` for a fake camera stream. After hiding
  the native owner, `document.pictureInPictureElement === tile` remains true.
  Both fake capture tracks are stopped and PiP is exited before shutdown.

`respondToModalDialogForTesting:` extends the existing mock-keychain,
unsigned-scratch `modalDialogs` gate to invoke the same Accept/Cancel handlers
as native buttons. It is unavailable to ordinary app runs. Return initially
exercised Stay (the dialog's deliberate default), and DevTools cannot accept
this hosted native dialog; neither was treated as proof of Leave.

The runner also checks persistent two-profile write/restart/read isolation,
memory/discard, extension installation/action popup/profile separation, and
four dialog scenarios: HTTP auth Cancel, beforeunload Cancel, auth tab-close,
and platform passkey cancellation. It checks each report and rejects native
crash markers, including shutdown failures. Hybrid Bluetooth passkeys remain
outside this noninteractive run.

`make-pass12-patch.py` generates the exact Swift diff without editing app-owned
files and writes optional isolated adapter sources under ignored engine build
output. The patched engine protocol/Chromium adapter type-check with
`swiftc -warnings-as-errors`; the WindowController/Peek UI integration is supplied
for the app agent to compile with its ongoing work. `git apply --check` passes
against the app snapshot used for generation. The strict apply test exercises
apply/check/repeat/drift refusal on a small copy and confirms the source mirror
is unchanged: 54 pinned files, 25 patches.

Needs eyes: picker placement, scrolling and keyboard selection; PiP placement,
window restoration, native fullscreen and actual call sites. Full automatic
multi-tile call PiP and reliable generic microphone controls are **not shipped**.
The Little Arc lifetime/UI and password picker UI remain app-agent integration.


Final output:

```text
PASS dev: 9 scenario reports; DCHECKs=1; screen locked; no native crash markers
PASS release: 9 scenario reports; DCHECKs=0; screen locked; no native crash markers
PASS Swift adapter and Objective-C selector import typechecks (warnings as errors)
PASS strict patch apply/check/repeat/drift refusal; source mirror unchanged
```

The last incremental dev and release builds each completed 38 steps with
`EXIT 0`. Both ran sequentially in `airc-engine`; release was last. Evidence
includes the full build logs, `SUMMARY.txt`, both final scenario directories,
initial dev regression evidence, adapter/selector typechecks and cleanup log.
The owned Mac work copy was deleted after all test processes exited. No push
was performed and no app/package source was edited.

# Passkeys on the Mac

Airc uses Chromium's Mac profile authenticator. It stores private keys in the Secure Enclave / local Keychain;
credentials are local to this Mac and Airc profile. It does not require Google sign-in. This is separate from
iCloud Keychain, which belongs to the user's Apple account and survives deleting an Airc profile.

## Signing and build channels

- Stable / public Nightly: the existing CloudKit Developer ID profile grants `<team>.*` Keychain access.
  `package.sh` embeds it; `scripts/release/sign.py` now adds `<team>.com.aircbrowser.Airc.webauthn` to the **main app**.
  The engine derives the same group from its signed application identifier. It never compiles a team identifier
  into the framework. A profile that grants only the CloudKit group will not enable local passkeys.
- Private dev feed (`org.airc.Airc.dev`): Developer ID signing alone is insufficient. Its current staging path does
  not embed a matching provisioning profile. The Stable profile is for a different App ID and cannot be reused.
  Dev can support passkeys too: obtain a Developer ID profile for that dev App ID and signing certificate with
  its own `.webauthn` group (or `<team>.*`), embed it in the staged app **after restoring the published bundle ID,
  before sign.py**, and retain that step in the dev publisher. No extra managed capability is needed for local keys.
- Ad-hoc developer/test bundles cannot use the signed group; their native local authenticator remains unavailable.
  Virtual authenticators are for tests only. Distribution signing continues to disable the engine's test hooks.
- Frameworks, helper apps, renderers, GPU, CDM helper and Sparkle receive no profile entitlements. The nested
  entitlement gate rejects leakage. Manual extras outside the embedded profile fail before code signing.

## Engine paths

`031-passkeys.patch` changes only the access-group source in
`ChromeWebAuthenticationDelegate::TouchIdAuthenticatorConfigForProfile`. It preserves Chromium's generated
`webauthn.touchid.metadata_secret` preference. The request delegate, credential enumeration and local credential
manager all use this config, so modal sign-in and conditional autofill share the same profile isolation.
`HostPasswordSuggestions` leaves lists containing WebAuthn credentials or the other-device action to Chromium's
native popup, including mixed password/passkey lists. Previously the host's password-only filter swallowed these
rows. Chromium's normal dialog says “Your Airc profile” through Airc's two explicit profile-label overrides (the upstream strings say Chrome even in unbranded builds).
It offers Touch ID and macOS device-password user verification without an Airc authentication bypass.

`airc_passkeys.mm` removes local credentials before `AircEngine.deleteProfile` schedules deletion of the profile
folder. Work runs off the UI thread, retains the profile until completion, and uses its original metadata secret.
A real Keychain error returns failure and preserves the profile instead of discarding the secret. Cleanup includes
resident and nonresident credentials, leaves other profiles' credentials intact, and treats an empty access group
as success. Ad-hoc profiles have no access to the signed store. Manually removing profile folders is unsupported:
it discards the metadata secret and can orphan Keychain entries. Losing/corrupting the secret cannot be repaired
by inventing another one.

M156's iCloud authenticator is already enabled: `device/fido/mac/icloud_keychain_sys.mm::IsAvailable` checks the
process entitlement. `ConfigureICloudKeychain` enables the chooser for web authentication; the
`WebAuthnICloudKeychainUseDeviceConfiguredForPasskeys` feature is enabled by default. The two disabled
“WithoutDrive” experiments control which provider is preferred on an unconfigured Mac, not availability.
Airc does not force those experiments or request Apple authorization in an unentitled build.

## iCloud Keychain owner step

1. Sign in as the organization account's **Account Holder**. Open Apple Developer → **Certificates, Identifiers
   & Profiles → Identifiers → com.aircbrowser.Airc → Capability Requests**.
2. Request **macOS Browsers Passkeys** (`com.apple.developer.web-browser.public-key-credential`) and complete the
   [browser eligibility form](https://developer.apple.com/contact/request/macos-browsers-passkeys/). Use that
   direct form if the capability is not listed in the portal.
3. After Apple approves it, return to that App ID → **Capabilities**, enable the approved capability and Save.
4. Regenerate/download the **Developer ID** provisioning profile for that App ID using the build's actual
   Developer ID Application certificate. Preserve CloudKit and the Keychain groups. Replace the profile in the
   builder's configured `AIRC_ICLOUD_PROFILE_DIR`; do not put it in git.
5. Package a new signed build. `sign.py` adds the managed entitlement only when the decoded profile grants `true`;
   `icloud.py verify` checks the signed main app, profile certificate and all nested code. An entitlement plist
   alone does not grant access. On the first attended request, approve Airc's system passkey access if asked.

Apple sources: [browser entitlement and eligibility](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential),
[capability requests and enabling approved capabilities](https://developer.apple.com/help/account/capabilities/capability-requests),
[passkey access in browsers](https://developer.apple.com/documentation/authenticationservices/passkey-use-in-web-browsers).

## Verification

Linux: `python3 -m unittest discover -s scripts/release -p 'test_*py'` and
`engine/apply.sh --check --src "$CHROMIUM_SRC"`. Build the release engine under the ship and agent build locks.
Build `airc/core:passkeys_store_test` in the same output. Package that executable as a small .app with the
public bundle identifier and embedded profile, sign with `scripts/release/sign.py`, then run its executable
without Launch Services. It creates only synthetic `passkeys.invalid` keys with fresh random metadata secrets,
checks real Secure Enclave signing/verification, resident enumeration, cross-secret isolation, scoped deletion,
the surviving profile, repeated empty deletion, and cleanup. It does **not** simulate owner authentication.

`engine/host/passkeys/main.mm` is an ad-hoc, scratch-profile WebAuthn host for virtual creation, discoverable
sign-in, resident enumeration and removal, without native user input. Its CDP focus emulation affects only the
virtual test page; it never activates the application. Chromium still requires browser-side visibility: the
fixture refuses a hidden, occluded or off-Space window with recorded window/page evidence. Retry on an idle
display with the fixture visible; focus emulation alone cannot satisfy that gate. Build from a clean
source export plus these fixture files, under the agent build lock:

```sh
CHROMIUM_OUT="$HOME/arcfork/chromium/src/out/AircRelease" \
AIRC_HOST_SOURCE="$PWD/engine/host/passkeys/main.mm" \
  engine/host/build.sh build/passkeys-host
python3 engine/host/passkeys/run-virtual.py build/passkeys-host/AircHost.app build/passkeys-virtual
```

The runner creates disposable loopback TLS and scratch data, takes `scripts/ui-check-lock.py`, launches with
`open -g -n -W`, and refuses UI lock timeouts. Use a new output directory for every run. Remove the scratch build
and profiles after copying the results; the runner deletes its temporary TLS key and terminates its own host.
This is not evidence of a physical authenticator, conditional dropdown drawing, or a successful native prompt.

For the attended end-to-end test, serve `engine/host/passkeys/fixture.html` with `serve.py CERT KEY PORT` using a
localhost certificate (SAN `DNS:localhost`). On a real signed build, use a fresh Airc profile:

1. Create a passkey; select **Your Airc profile** and complete Touch ID or device-password verification.
2. Sign in with the modal picker. Choose autofill sign-in, focus the username field, select the same passkey and
   verify again. Cancel and retry once. Create a second profile's passkey too and confirm isolation.
3. Delete the first profile through Airc, recreate it, and confirm the credential is gone while the second
   profile's credential remains. The fixture does not persist accounts or validate server-side sessions.
4. After Apple approval, repeat with **iCloud Keychain**. Deleting the Airc profile must not delete that synced key.

No unattended Touch ID/device-password dialog, Apple authorization prompt, Bluetooth pairing, or owner data
is used by these probes. Marketing screenshots and native picker/autofill presentation need the attended run;
no screenshot of a virtual authenticator stands in for them. See the task's private artifact report for actual
build and test results rather than treating this procedure as a pass.

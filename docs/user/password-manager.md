# Your password manager

Onboarding has a step for the password manager you use, after the import and before the colours. It's optional:
**Not now** changes nothing, and **Settings › Import › Your password manager › Choose…** opens the same step later.

## The choices

1Password, Bitwarden, Dashlane, LastPass, Proton Pass, Keeper, NordPass and Apple Passwords add their Chrome
extension. Apple Passwords is Apple's **iCloud Passwords** extension: it fills from the Mac's Passwords app.
**Airc's own** keeps your logins and passkeys in Airc, with nothing to install.

Airc picks one for you when it can tell, without reading anything private:

- a password manager's Mac app is in Applications (1Password, Bitwarden, Dashlane, LastPass, Proton Pass, Keeper or
  NordPass). Airc only checks that the app is there;
- otherwise, the Arc import's extension checklist has one of them;
- otherwise, nothing is picked.

## Adding it

Choose the profiles it goes to. The profiles the import brought are ticked; from Settings, every profile is. **Add**
installs the extension into each one in turn, with that profile's own permission review on the onboarding window, the
same review as **Install in all profiles…** ([extensions.md](extensions.md)). Profiles that have it already are skipped.
Afterwards each profile has a line: installed, already installed, declined or failed (with the reason). A profile it
didn't reach has **Open in Web Store**, which opens the extension's page in a Space of that profile.

**Turn off Airc's offer to save passwords** is on by default: in the profiles that got the extension, Airc stops asking
to save a login when you sign in, so your password manager is the one that asks. Turn it back on per profile in
**Settings › Import › Your password manager**. Logins you already saved in Airc stay.

Then sign in to the extension: most of them connect to their Mac app, or ask for your account.

## Passkeys

A passkey signs you in to a site without a password. With **Airc's own**, a site can save one in your Airc profile, on
the Chromium engine, in the signed Airc download (test and developer builds can't).

**Creating one.** When a site offers a passkey (on GitHub: **Settings › Password and authentication › Add a passkey**),
Airc shows **Create a passkey for github.com** with your account name, and says it's saved in your Airc profile on this
Mac. Click **Use Touch ID** and touch the sensor. On a Mac without Touch ID, or with the lid closed, the button says
**Use password** and macOS asks for your Mac's password instead.

**Signing in.** Click the site's passkey button, or click its username field: your passkey is in the list with its
account name. Pick it, then use Touch ID or your Mac's password. Airc asks every time; a passkey never signs you in
without you.

**Where they're kept.** In that Airc profile, on this Mac. The key stays in the Mac's Secure Enclave, and the Mac only
uses it after Touch ID or your password. Each profile has its own passkeys, and deleting a profile deletes them. They
don't sync to your other Macs.

**Not yet:** passkeys in iCloud Keychain (Apple Passwords). Airc needs Apple's permission for that first.
Until then, a passkey on your iPhone works through **Use a phone or tablet** in the same window: scan the code with the
phone. It uses Bluetooth.

## On the WebKit engine

Chrome extensions need the Chromium engine. On WebKit the step says so, and only **Airc's own** and **Not now** do
anything.

Passkeys don't work in WebKit pages yet: macOS gives them only to browsers Apple has approved. Sites see no passkey
support there and offer their other ways to sign in. In Airc-Chromium that includes the streaming sites that play in
WebKit pages ([protected-media.md](protected-media.md)).

## Privacy

The step records only how it ended (an extension added, not added, Airc's own, or Not now), never which manager or
profile ([telemetry.md](telemetry.md)).

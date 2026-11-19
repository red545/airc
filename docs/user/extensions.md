# Extensions

Airc runs Chrome extensions from the Chrome Web Store. Extensions belong to a profile: each profile has its own, and a
Space shows the extensions of its profile.

## Using an extension

- **⌘E**, or the puzzle button, lists the profile's extensions. Click one to use it; its switch pins it.
- **Pinned extensions** show their icon and badge. Click one to open its popup under it.
- Without the toolbar, they're in the sidebar's URL field while the pointer is over the sidebar.
- With the toolbar on (**View › Show Toolbar**, **⇧⌘D**), they move to the toolbar's top right, as in Arc. They're
  always visible there, with the puzzle button after them. Turn the toolbar off and they go back to the URL field. They
  keep the same order either way.
- Pins keep the order you pinned them in; a newly pinned extension goes last. If the toolbar is too narrow for all of
  them, the rest are in ⌘E's list.
- A popup opens under its button. In the toolbar, or with the sidebar on the right, its right edge lines up with the
  button's; with the sidebar on the left, its left edge does. It always stays on the screen.
- An extension can open its own popup too (Chrome's `chrome.action.openPopup`), for example 1Password's **Unlock
  1Password** button on its in-page card. The popup opens in the same place as when you click its button: under its
  pinned button, else under the URL field (or the toolbar's puzzle button), else at the window's top left when the
  sidebar and toolbar are hidden. As in Chrome, this doesn't give the extension access to the page; clicking its
  button does. **Esc** or a click outside closes it, and so does clicking its button again.
- A popup takes the size its extension asks for (up to 800 × 600), the same as in Chrome: Proton Pass's is 600 × 430.
- On a page an extension can't run on, such as the Web Store, its icon is greyed out. On a streaming site that plays in
  Safari's engine, it also says why: extensions don't run there.

## Adding extensions

Open **Chrome Web Store…** from ⌘E's list (or go to chromewebstore.google.com) in a Space of the profile you want, then
choose **Add to Chrome**. Airc shows what the extension can do and which profile it goes to before it's added.
**Manage Extensions…** opens chrome://extensions for that profile.

**Install in all profiles…** (right-click an extension in ⌘E's list) asks Chromium to install it in each profile.
Each new installation has its own permission review, showing the destination profile. Profiles that already have the
extension are skipped. A profile without a Space uses the current window for its review; no Space or tab is created.
The result lists installed, already installed, denied, failed (with a reason), or blocked by policy for each profile.
Cancelling one review continues to the next profile.

Onboarding's **Your password manager** step ([password-manager.md](password-manager.md)) uses the same reviews to add
a password manager to the profiles you choose. Arc import's **Reinstall your extensions → Install all** uses the same reviews, keeping each extension in the
profile it came from. Extensions from outside the Web Store still need to be reinstalled from their original source.

## Password managers and their Mac app

Password manager extensions such as 1Password talk to their Mac app through Chrome's native messaging. The app
installs a small file for each browser it knows (Chrome, Arc, Edge, Brave and others). Airc also uses the ones
installed for Chrome, Chromium, Arc, Chrome Beta, Dev and Canary, Edge and Brave (in that order), as Arc does, so you
don't need to install anything for Airc. A file put in Airc's own folder (`~/Library/Application Support/Airc/Chromium/NativeMessagingHosts`)
always comes first.

### Turning off Airc's own passwords

**Settings › Passwords › Offer to save and fill passwords in <profile>** is on by default: Airc asks to save a login
when you sign in and lists your saved logins under the field. Turn it off and Airc does neither in that profile, so
your password manager's extension (1Password, Proton Pass, Bitwarden…) is the only one asking and filling; its list no
longer competes with Airc's for the same field. Logins already saved in Airc stay, and turning it on again brings
everything back.

The first time a profile has a password manager's extension turned on, a small card at the bottom right asks once:
**Use <manager>** turns Airc's saving and filling off in that profile, **Keep Both** leaves it on. It doesn't take the
keyboard or cover the page, and it never comes back for that profile.

Passkeys are separate: a password manager that handles passkeys takes a site's passkey request itself (see below).

### 1Password

The 1Password app only connects to browsers it trusts. Airc isn't on its built-in list yet, so the extension stays
locked even when the app is unlocked, and its in-page cards say "unlock 1Password first". To connect them:

1. Open and unlock the 1Password app.
2. Click your account or collection at the top of the sidebar, then choose **Settings**.
3. Choose **Browser**, make sure **Connect with 1Password in the browser** is on, then click **Add Browser…** and
   choose Airc in the Applications folder.
4. Quit and reopen Airc. Unlocking the 1Password app now unlocks the extension too, and its **Unlock 1Password** button
   asks the app (Touch ID).

Without this step, **Unlock 1Password** opens the extension's popup under its button, where you can unlock it with
your account password. The same happens when you click 1Password's button inside a login field while it's locked.

**Passkeys with 1Password.** When 1Password saves and offers passkeys, its extension handles a site's passkey request
before Airc does, the same as in Chrome: you see 1Password's **Save passkey?** card, not Airc's **Create a passkey**
dialog. When 1Password is locked ("To save a passkey, unlock 1Password first"), close its card with ✕, or choose its
security key button, and the site's request goes on to Airc's own dialog ([password-manager.md](password-manager.md),
"Passkeys"). If you haven't signed in to an account in the extension yet, 1Password shows no card and the request goes
straight to Airc's dialog. To keep using Airc's passkeys instead, turn this off in
1Password: open its popup, choose the account menu at the top left, then **Settings › Autofill & save**, and turn off
**Offer to sign in with passkeys** and **Offer to save passkeys**.


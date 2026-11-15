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

# Localization

Airc is English-only until it is localized. Every string should be in one language, English, on a Mac set to any
language.

## How the app's language is chosen

- `apps/browser/Resources/Info.plist` has `CFBundleDevelopmentRegion = en` and `CFBundleLocalizations = [en]`.
  `apps/browser/Resources/en.lproj/InfoPlist.strings` is the only `.lproj` in the app bundle. `scripts/build-app.sh`
  copies it in, and release packaging (`scripts/release/package.sh`, then `sign.py`) builds through build-app.sh and
  seals it with the rest of `Contents/Resources`.
- AppKit resolves the app's language from those localizations. It lands on `en` whatever the Mac's languages are, so
  the items macOS adds are English next to Airc's own English titles: Edit's Start Dictation, Emoji & Symbols and
  AutoFill; the Window menu; alerts; panels; a text field's menu with its Spelling and Substitutions submenus.
  LaunchServices records the bundle as `en` too. Out-of-process UI such as the Open panel service reads that record.
- Chromium takes its UI locale from the app bundle's resolved localization (`l10n_util::OverrideLocaleWithCocoaLocale`,
  `base::apple::OuterBundle().preferredLocalizations`). That gives `en-US`, so the strings Chromium supplies (its part
  of the page menu, its dialogs and permission text) are English. The framework's own `locale.pak` files stay, unused.
- Don't add a `.lproj` folder to the app (a nib's `Base.lproj` or a translated `MainMenu.strings`) without localizing
  the whole app. AppKit would then switch to that language for its own items on Macs set to it.

## What stays the Mac's

- **Region formats.** The region still controls dates and numbers. With `-AppleLocale de_AT`, `Locale.current` is
  `en_AT`: English words, Austrian formats (1.234,5; day before month).
- **Site language (WebKit).** WebKit sends sites the Mac's first preferred language (`navigator.languages` is
  `["de-DE"]` on a German Mac).
- **Site language (Chromium).** Chromium sends `intl.accept_languages`. A profile stores that list the first time it
  opens, from the UI locale at that moment, and keeps it afterwards, so a profile that already exists keeps its list.
  A new profile gets `en-US,en` (`IDS_ACCEPT_LANGUAGES` for en-US). Airc doesn't yet seed it from the Mac's preferred
  languages, so sites see English there even on a German Mac. That was also true before English became the declared
  localization: the bundle had no `.lproj`, so it already resolved to `en`. Changing it means seeding the selected
  languages from `NSLocale.preferredLanguages` on profile creation (engine, `language::prefs::kSelectedLanguages`).
  The `--accept-lang` switch would also work, but it overrides the person's own choice on every launch.

## Arc, for comparison (Arc 1.171)

Arc's Info.plist has `CFBundleDevelopmentRegion = en` and no `CFBundleLocalizations`. Its bundle has a `Base.lproj`
(MainMenu.nib) and about 55 `<lang>.lproj` folders with a `MainMenu.strings` each. Those files translate almost
nothing: `de.lproj` has two strings, "Bearbeiten" (Edit) and "Kopieren" (Copy). Their presence makes AppKit, and
ArcCore's Chromium (which ships every `locale.pak`), run in the Mac's language. Arc on a German Mac therefore mixes
English titles with German system items and German Chromium strings. Airc deliberately doesn't copy that.

## Checking it

`--script menulang` (`apps/browser/Sources/Airc/Debug/MenuLanguageCheck.swift`) runs in build-app.sh's suite on both
engines with `-AppleLanguages '(de)' -AppleLocale de_AT`. It checks that the menu bar, a text field's menu, the page menu
on a page and in a text field, an alert and the Open panel contain no German. It also checks that region formats
stay Austrian and that WebKit sites still get German. It writes `menulang-*.png` drawings of each menu's live items.

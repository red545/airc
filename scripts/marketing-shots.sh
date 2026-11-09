#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Refreshes the marketing screenshots from the real app (assets/screenshots/README.md).
#
#   scripts/marketing-shots.sh                        build on the build Mac, shoot every part, write both sets
#   scripts/marketing-shots.sh --no-build             shoot with this copy's last build
#   scripts/marketing-shots.sh --parts views,media    only these parts (browser, views, media, calls, settings, onboarding,
#                                                     boosts, drm, basics, previews, windows, sidebarright, multiselect,
#                                                     shortcuts)
#
# From the Linux box, through scripts/mac.sh (copy name: AIRC_MAC_WORK, default marketingshots). On the build Mac:
#   1. scripts/build-app.sh --no-test, linking the Chromium framework at CHROMIUM_OUT (default: the release build,
#      ~/arcfork/chromium/src/out/AircRelease).
#   2. build/Airc-Chromium.app --script marketing (apps/browser/Sources/Airc/Debug/Marketing*.swift), one launch per
#      part: `open -g`, never focused, the window off screen, everything it writes in build/marketing-home (deleted
#      afterwards). It loads real public sites, so it needs the network. The call, film, radio and shared-folder pages
#      are served on 127.0.0.1 and reached as *.aircbrowser.com through the engine's host rules, so nothing in a shot
#      reads 127.0.0.1 and no request for them leaves the Mac. No camera, microphone or screen capture.
#   3. sips and cwebp (Google's libwebp release, fetched once into ~/arcfork/tools/libwebp and checked) make WebP copies
#      at most 2400 px wide.
# Then the originals (PNG, 2×) go to $AIRC_MARKETING_ORIGINALS/<date>/ (default: artifacts/marketing next to the repo),
# the WebP copies to assets/screenshots/, and assets/screenshots/README.md is rewritten with the date and the build.
# Not part of the suite (real sites, about ten minutes). Look at every image before committing it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PARTS="blocking smallwins arcbits arcimport2 profilesignin boostsplus archive browser views media calls settings sync onboarding boosts themes drm basics previews windows sidebarright multiselect parityp01 parityp21b capture notes parityp07 parityp03b parityp09 parityp20d library parityp10 shortcuts devmode routing ai"
BUILD=1
ON_MAC=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-build) BUILD=0 ;;
    --parts) PARTS="$(echo "$2" | tr ',' ' ')"; shift ;;
    --on-mac) ON_MAC=1 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

# Each shot: file name | feature | what it shows. The README's table comes from this list.
SHOTS='blocking|Ads and trackers|Built-in blocking in Site Controls, on a synthetic Field Notes story served only over loopback
extension-profiles|Extensions in every profile|Per-profile Web Store results, including a profile with no Space and no silently created Space
backup-restore|Restore from Backup|The backup picker with date, size and counts, before replacing Spaces, tabs and archive
show-toolbar|Show Toolbar|A full address bar above a synthetic reading page, with back, forward and reload
copy-quote|Copy URL as Quote|Command Bar copy commands for a synthetic reading page
remembered-profiles|Little Arc profiles|Settings → Links, with remembered profiles and Forget remembered profiles
arc-import-checklist|Arc import|Per-profile history counts and localized extension names in the reinstall checklist, from synthetic Arc data
arc-import-logins|Logins from Arc|Every login and each site’s cookies with what happened: what couldn’t come over and why, and Try Again for the profile whose passwords couldn’t be read, from synthetic Arc data
profile-sign-in|Google sign-in|A new profile signed in as a synthetic account, with Gmail and Calendar offered as Favorites
boost-import|Share a Boost|A shared Boost reviewed before it'"'"'s added: a sketch of what it changes, the full CSS and JavaScript with its warning, and Try It On
archive-library|Archived Tabs|The searchable Archive and its confirmed Clear Archive action, across all Spaces and profiles
developer-mode-dark|Developer Mode, dark|Developer controls in a dark Space
developer-mode-narrow|Developer Mode, narrow|Compact developer controls at the minimum sidebar width
developer-mode|Developer Mode|A synthetic app on localhost, in Developer Mode by itself: its full URL, Inspect, Network, Hard Reload, the console error count and the outlined sidebar row
developer-mode-site-controls|Developer Mode: Site Controls|Site Controls on the same local app: the Developer Mode switch for the site, which follows it to every tab and port
ai-ask-page|Ask on Page|⌘F in Ask mode on a synthetic Lisbon guide: Apple Intelligence'"'"'s answer, the page'"'"'s sentence behind it, scrolled to and highlighted
ai-link-preview|Link previews|⇧ over a link on a synthetic reading list: the on-device summary and key points of the article it opens
ai-tidy-downloads|Tidy downloads|Library › Downloads: a suggested name for "IMG_2041 (1).pdf" (a synthetic itinerary) and Rename
ai-settings|Settings → AI|Tidy tab titles, Ask on Page, Link previews and Tidy downloads, all on this Mac
hero-light|The window|Personal Space in Mint: Favorites, pinned folders, Today tabs and apple.com on the page card
hero-dark|The window, dark|The Work Space (Grape, the Work profile) on linear.app, in dark mode
spaces|Spaces|Four Spaces side by side, each in its own colour and profile: Personal, Travel, Studio, Work
command-bar-light|Command Bar (⌘T)|"lisbon" in Travel: history, open and pinned tabs and live search suggestions, the top hit completed inline
command-bar-dark|Command Bar (⌘T), dark|"linear" in the dark Work Space, from the Work profile'"'"'s own history
command-bar-sites-light|Command Bar: well-known sites|"spot" with no history of it: Spotify first with its own icon, spotify.com completed inline
command-bar-site-search|Command Bar: Site Search|"wiki", Tab, "Belém Tower" in Travel: the Wikipedia pill leads the field, the search first, then your Wikipedia pages
command-bar-site-search-hint|Command Bar: Search Wikipedia|"wiki" typed in Travel: the "Search Wikipedia · Press Tab" row under the top hit
command-bar-remove-suggestion|Command Bar: remove a suggestion|"lisbon" in Travel with the pointer on a history row: its ✕ removes the page from the suggestions and the history (⌥⌘⌫ from the keyboard)
settings-site-search|Settings: Site Search|Each profile'"'"'s sites with their shortcuts and %s addresses, Wikipedia as the default search engine, and adding one
toolbar-extensions|Extensions in the toolbar|Show Toolbar (⇧⌘D) in Work on linear.app: the pinned extensions at its top right, ⌘E'"'"'s list under the puzzle
task-manager|Task Manager|Help › Troubleshooting › Open Task Manager over Work: each tab, the browser and its helpers with memory, CPU and process ID
profiles|Profiles|Create Profile, step 2: which Spaces move to the new profile, each in its own colour
split-view-2|Split View|Two panes in Studio: Apple design pages beside Color theory
split-view-3|Split View, three panes|A map, the city and its trams in Travel
pinned-split|Pinned splits|A split pinned as one row in Studio (Bauhaus and Helvetica)
favorite-split|Favorite splits|A split as one Favorite tile in the Work profile (Linear and SwiftUI), dark
favorite-split-icon|Favorite split icons|The same Favorite split with its own icon (Change Icon…, as in Arc), dark
peek|Peek|A link from the Lisbon article opens over the page: the map of Belém
little-arc|Little Arc|A link from another app in its own small window, over the Personal Space
little-arc-menu|Little Arc: Open In|The chip'"'"'s chevron: the Spaces in their own colours, ⌘O on Personal, Work reloading in its own profile, Search Spaces, Profile and Copy Link
sidebar-files|Files and folders|A "Lisbon trip" folder dropped on the Travel sidebar: a pinned folder with its files as tabs and its Tickets folder inside, the itinerary open from disk
multi-select|Multi-selection|Three Today tabs ⌘-clicked in Personal, with their menu: copy, share, duplicate, split, pin, a new folder, move, close, archive
tab-menu|Tab menus|The Kyoto tab'"'"'s menu in Personal, as Arc'"'"'s: Copy Link, Share, Rename, Mute, Customize Page, Add Split View, Move to, Archive
folder-markdown|Folder links as Markdown|The Recipes folder'"'"'s menu: Copy All Links and Copy All Links as Markdown, titles and order kept
quote-link|A link to copied text|After ⌘C on a sentence in Wikipedia'"'"'s Typography article: Share a link directly to this text instead? with Copy Link
essential-shortcuts|Essential Keyboard Shortcuts|Help › Essential Keyboard Shortcuts: tabs, Spaces, pages, Split View and notes, each with the key it has now
library-media|Library: Media|Library › Media in the Work Space: downloaded pictures and films and a Capture, newest first, as a grid of thumbnails
library-recent|Library: recent files|The pointer resting on the Library button: the five newest downloads and Captures in a card above it
library-folders|Library: folders|Library › Media showing a Desktop folder the person allowed: pictures and a film from the top of the folder, newest first
library-notes|Library: Notes|Library › Notes: every note in one list, newest first, wherever its row is (two Spaces, a closed folder)
capture|Capture (⇧⌘2)|A card on a trip-planning page selected with Capture: the page dimmed around it, and Copy, Save and Share under it
capture-full-page|Capture Full Page|A long trip itinerary taken with Capture Full Page: the whole page shown over the dimmed card, its size above it, Copy, Save and Share under it
capture-portrait|Capture in Portrait Mode|The trip page framed in Portrait Mode on a soft cyan gradient with the Airc mark, the background choices under it, then Copy, Save and Share
notes|Notes (⌃⇧N)|A note pinned in Travel: a few lines, a checklist with one tick, and a Capture of the trip page pasted into it
notes-split|New Note in Split|The Lisbon trip page with a packing note beside it in Split View, the note being written
sidebar-right|Sidebar on the right|Settings → Appearance → Sidebar position: Right. Travel on the Lisbon article, the traffic lights over the page
multiple-windows|Several windows|Two windows on different Spaces, each with its own tab: Travel on the Lisbon article in front, Work on linear.app behind
private-window|Private windows|A private window (⇧⌘N): dark, its own tabs and New Tab, nothing kept, on Wikipedia'"'"'s Private browsing
private-window-start|Private windows: a new one|A new private window before its first tab: what it keeps and what it doesn'"'"'t
private-window-find|Private windows: find|⌘F in a private window: "cookie" found on Wikipedia'"'"'s Private browsing, the same find field as the main window'"'"'s
manage-spaces|Manage Spaces|Every Space in one card: drag to reorder, rename, icon, theme, profile and delete
media-controls|Media controls|A background radio tab with artwork, pause, skip and seeking in the sidebar, over Kyoto on Wikivoyage
calendar|Live Calendar|The Calendar Favorite counting down to the next meeting, and its card: a big Join for the one moments away, + for a new event
calendar-join|Live Calendar, Join|A minute before: the meeting and Join under the Favorites
site-controls|Site Controls|Site Controls from the URL field on swift.org: Capture, Capture in Portrait Mode and Copy link, permissions, zoom and site data for that site
boosts|Boosts|Wikipedia boosted into a warm, bookish page (an amber tint, Charter), the Boost editor open on Colors
boosts-font|Boosts: fonts|The same Boost on Font: the page in Charter, a size step up, the macOS fonts to choose from
boosts-zap|Boosts: Zap|The same Boost on Zap: Wikipedia'"'"'s Appearance column zapped away, with its undo
boosts-gallery|Boost Gallery|Airc'"'"'s starter Boosts: each a sketch of its colors and font, with Get to review and add it
boosts-share|Share a Boost|The share sheet over the boosted Wikipedia page: its screenshot, a name, the author, Copy Link and Save File
theme-palette|Space colors on pages|Wikipedia in the Peach Space wearing its theme through Arc'"'"'s --arc-palette-* variables (a Boost of nothing else)
theme-palette-dark|Space colors on pages, dark|The same page and Boost in the Grape Space: the page turns dark with the theme
boosts-review|Boost: Try It On|A shared Boost under review with Try It On: Wikipedia already shows it behind the sheet, before it'"'"'s added
tab-preview|Tab previews|The pointer resting on the Kyoto tab over apple.com: its card with the page as it was left, and pin, Favorites, split and Peek
tab-preview-dark|Tab previews, dark|The Work Space in dark mode on linear.app: the card of the swiftlang/swift tab
site-preview|Site previews|The Work Space: resting on the Linear Favorite shows the Linear pages visited there, newest first, with + for a new issue
drm-spotify|Protected media|Spotify'"'"'s web player, logged out, in Safari'"'"'s engine with Apple'"'"'s FairPlay: the note that says so, with Why?
drm-site-controls|Protected media: Site Controls|Site Controls on Spotify: the Safari'"'"'s engine switch, and what a WebKit page does differently
mini-player-hidden|Hidden Mini Player|Playback continues in the sidebar media tray while the floating window is hidden
mini-player-pill|Minimized Mini Player|A playing film collapsed to its title and pause button
picture-in-picture|Picture in picture|A playing film over the Lisbon article: Back to Tab, hide, skip 15 s, pause and the scrubber
picture-in-picture-call|Picture in picture, call|A call'"'"'s video floating over another page, with microphone, camera and Leave
picture-in-picture-meet|Picture in picture, Meet|A call page'"'"'s requested 640 × 400 Document PiP, with its full control row below Airc'"'"'s slim top bar
downloads|Downloads|A film downloading, with its progress in the sidebar
downloads-library|Downloads Library|The Library'"'"'s Downloads list: finished files and the one still running
call-window|Call window|A resizable 800×600 call page (illustrated tiles, no camera), its own controls below a permanent Airc bar
settings-appearance-light|Settings: Appearance|Translucency, the default look of new Spaces and Show tab previews
settings-appearance-dark|Settings: Appearance, dark|The same page in dark mode
settings-links|Settings: Links|Air Traffic Control routes links leaving a site before Peek, and external links into Spaces
settings-privacy|Settings: Privacy|Anonymous usage data and crash reports, off with one switch
settings-privacy-events|See what Airc sends|The sheet listing every event Airc recorded, word for word
settings-sync|Settings: Sync|iCloud sync on, up to date between two Macs, with what syncs and what never leaves the Mac
settings-sync-first|First sync on another Mac|Both sidebars side by side, the other Mac'"'"'s Work profile matched to this one'"'"'s, then merge or replace (a backup first)
settings-shortcuts|Settings: Shortcuts|Every command by menu with its key and who gets it first: Open Location at Airc first (pages never get ⌘L), and ⌘N typed for New Private Window asking to swap with New Window
onboarding-welcome|Onboarding|The first window
onboarding-import|Onboarding: Arc import|Arc found on the Mac, first among the browsers found: Spaces, pinned tabs, folders and Favorites come over as they are
onboarding-import-browsers|Onboarding: other browsers|Chrome picked on the same step: each profile with its colour, its bookmarks and folders, and the history for ⌘T
onboarding-profiles|Onboarding: profiles|Each Arc profile becomes an Airc profile, with its Spaces
onboarding-colours|Onboarding: Space colours|A colour for each Space before the first window opens
onboarding-default-browser|Onboarding: default browser|The default-browser step
onboarding-done|Onboarding: done|The last card before the window opens
update-button|Update button|A downloaded update waiting in the sidebar (a fake ready update)
update-whats-new|See What'"'"'s New|The update pill'"'"'s menu on apple.com in Personal: Restart to Update, and See What'"'"'s New for the update'"'"'s release notes
update-playing|Restart to Update asks first|Restart to Update with music playing in another tab: what it would stop, Restart or Not Now, and See What'"'"'s New
settings-app-icon|Settings: App Icon|Settings › Appearance › App Icon: Holographic or Outline in the Dock and the app switcher, Airc'"'"'s own artwork'

if [ "$ON_MAC" = 1 ]; then
  # ---- On the build Mac (macOS bash 3.2: plain [ ] tests only, no empty arrays). ----
  cd "$ROOT"
  free=$(diskutil info /System/Volumes/Data | sed -n 's/.*Container Free Space:.*(\([0-9]*\) Bytes).*/\1/p')
  [ -n "$free" ] || free=0
  if [ "$BUILD" = 1 ] && [ "$free" -lt 15000000000 ]; then echo "error: under 15 GB free on the build Mac ($free bytes); not building" >&2; exit 1; fi
  if ioreg -n Root -d1 2>/dev/null | grep -q '"CGSSessionScreenIsLocked"=Yes'; then
    echo "== warning: the screen is locked: the call and picture-in-picture shots need the window server and will be missing"
  fi
  export CHROMIUM_OUT="${CHROMIUM_OUT:-$HOME/arcfork/chromium/src/out/AircRelease}"
  if [ "$BUILD" = 1 ]; then caffeinate -i -s scripts/build-app.sh --no-test; fi
  app="$ROOT/build/Airc-Chromium.app"
  [ -d "$app" ] || { echo "error: no $app (does $CHROMIUM_OUT have the framework?)" >&2; exit 1; }

  WEBP="$HOME/arcfork/tools/libwebp/libwebp-1.5.0-mac-arm64/bin/cwebp"
  if [ ! -x "$WEBP" ]; then
    mkdir -p "$HOME/arcfork/tools/libwebp"
    (cd "$HOME/arcfork/tools/libwebp" &&
      curl -fsSLO https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.5.0-mac-arm64.tar.gz &&
      echo "0fa3d7fb64a2b2849115c2f1052b7068b3fbadcb7263e3f1840fcd8c798ea9c2  libwebp-1.5.0-mac-arm64.tar.gz" | shasum -a 256 -c - &&
      tar xzf libwebp-1.5.0-mac-arm64.tar.gz && rm libwebp-1.5.0-mac-arm64.tar.gz)
  fi

  out="$ROOT/build/marketing"; home="$ROOT/build/marketing-home"
  rm -rf "$out" "$home"; mkdir -p "$out/png" "$out/webp" "$home/Library"
  port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
  secure=""
  for h in meet video radio files; do secure="$secure${secure:+,}http://$h.aircbrowser.com"; done
  caffeinate -d -i -w $$ &
  for part in $PARTS; do
    echo "== marketing: $part"
    # English (UK) numbers and times whatever the Mac's own locale. Live search suggestions for the Command Bar shots
    # (one cookie-less request per query), canned elsewhere.
    live=0; [ "$part" = browser ] && live=1
    # iCloud sync through a mock CloudKit database and keychain in the run's own folder (MarketingSync.swift).
    sync_args=""; [ "$part" = sync ] && sync_args="--sync-mock $home/sync-cloud --sync-keychain $home/sync-keychain"
    # Synthetic unpacked extensions (parityp09) need the engine's test gate: its Chromium folder, --airc-data-dir.
    gate_args=""; [ "$part" = parityp09 ] && { mkdir -p "$home/$part/Chromium"; gate_args="--airc-data-dir=$home/$part --airc-test=unpackedExtension"; }
    # Local synthetic peers use direct host candidates; Airc routes the site PiP action.
    disabled_features=HttpsUpgrades
    case "$part" in calls|media2) disabled_features+=,WebRtcHideLocalIpsWithMdns; mkdir -p "$home/$part/Chromium"; gate_args="--airc-data-dir=$home/$part --airc-test=parityp16a --airc-switches=autoPip=off" ;; esac
    python3 "$ROOT/scripts/ui-check-lock.py" open -g -n -W --env "CFFIXED_USER_HOME=$home" --env "AIRC_MARKETING_PART=$part" --env "AIRC_MARKETING_PORT=$port" \
      --env "AIRC_LIVE_SUGGESTIONS=$live" --env "AIRC_SYNC_DEVICE_NAME=MacBook Pro" "$app" --args \
      --engine=chromium --snapshot "$out/png" --script marketing --ephemeral --data-dir "$home/$part" \
      --autoplay-policy=no-user-gesture-required "--host-resolver-rules=MAP *.aircbrowser.com 127.0.0.1:$port,MAP meet.localhost 127.0.0.1:$port" \
      "--unsafely-treat-insecure-origin-as-secure=$secure" --disable-features="$disabled_features" \
      -AppleLanguages '(en-GB)' -AppleLocale en_GB $sync_args $gate_args
    grep -q "marketing: $part done" "$out/png/log.txt" 2>/dev/null || echo "  marketing: $part didn't finish (crash or timeout; see log.txt)"
  done
  rm -rf "$home"
  grep -E "marketing: (MISSING|shot|pages not settled|.* didn't)" "$out/png/log.txt" | sed 's/^/  /' || true

  for f in "$out"/png/*.png; do
    [ -e "$f" ] || continue
    n=$(basename "$f" .png)
    case "$n" in _raw-*) rm -f "$f"; continue ;; esac
    w=$(sips -g pixelWidth "$f" | awk '/pixelWidth/ {print $2}')
    src="$f"
    if [ "$w" -gt 2400 ]; then sips --resampleWidth 2400 "$f" --out "$out/webp/$n.png" >/dev/null; src="$out/webp/$n.png"; fi
    "$WEBP" -quiet -q 86 -m 6 -sharp_yuv -metadata none "$src" -o "$out/webp/$n.webp"
    rm -f "$out/webp/$n.png"
  done
  /usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app/Contents/Info.plist" > "$out/build.txt" 2>/dev/null || echo "?" > "$out/build.txt"
  ls -l "$out/webp" | awk 'NR > 1 {printf "  %-36s %4d KB\n", $9, $5 / 1024}'
  exit 0
fi

# ---- On the Linux box ----
WORK="${AIRC_MAC_WORK:-marketingshots}"
DAY="$(date -u +%Y-%m-%d)"
ORIGINALS="${AIRC_MARKETING_ORIGINALS:-$(cd "$ROOT/.." && pwd)/artifacts/marketing}/$DAY"
# The source revision (AIRC_SOURCE_REV for a copy without .git, such as a `git archive` tree).
REV="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo "${AIRC_SOURCE_REV:-unknown}")"
if git -C "$ROOT" rev-parse HEAD >/dev/null 2>&1 && ! git -C "$ROOT" diff --quiet HEAD -- apps packages engine; then REV="$REV, with uncommitted changes"; fi
ARGS="--on-mac --parts $(echo "$PARTS" | tr ' ' ',')"
[ "$BUILD" = 1 ] || ARGS="$ARGS --no-build"
"$ROOT/scripts/mac.sh" -w "$WORK" run "AIRC_SOURCE_REV='${REV%%,*}' CHROMIUM_OUT=\${CHROMIUM_OUT:-\$HOME/arcfork/chromium/src/out/AircRelease} bash scripts/marketing-shots.sh $ARGS"
# This run's shots arrive in a folder of their own first, so the README dates only what was retaken.
INCOMING="$ORIGINALS/.incoming"
rm -rf "$INCOMING"; mkdir -p "$INCOMING" "$ROOT/assets/screenshots"
"$ROOT/scripts/mac.sh" -w "$WORK" get build/marketing/png/ "$INCOMING/"
TAKEN="$(cd "$INCOMING" && ls *.png 2>/dev/null | sed 's/\.png$//' | tr '\n' ' ')"
mv "$INCOMING"/* "$ORIGINALS/" && rmdir "$INCOMING"
"$ROOT/scripts/mac.sh" -w "$WORK" get build/marketing/webp/ "$ROOT/assets/screenshots/"
"$ROOT/scripts/mac.sh" -w "$WORK" get build/marketing/build.txt "$ORIGINALS/build.txt"
"$ROOT/scripts/mac.sh" ssh "rm -rf arcfork/work/$WORK/build/marketing"

# The README: one row per shot, with the date and build of the image that's there now.
BUILD_ID="$(cat "$ORIGINALS/build.txt") ($REV)"
README="$ROOT/assets/screenshots/README.md"
{
  cat <<'EOF'
# Screenshots

Product shots of the real app for the homepage, the launch posts and the press kit: Airc on the Chromium engine,
in a synthetic demo setup (four Spaces, two profiles, real public sites, nobody's data), on a code-drawn desktop.
WebP, at most 2400 px wide. The 2× PNG originals are kept outside the repo.

Refresh them after a user-visible change with one command (it builds on the build Mac and takes about ten minutes):

```bash
scripts/marketing-shots.sh                       # everything
scripts/marketing-shots.sh --parts views,media   # some parts: browser, views, media, calls, settings, onboarding
```

The scenario is `--script marketing` (`apps/browser/Sources/Airc/Debug/Marketing*.swift`). A new feature adds its shot
there and to the list in `scripts/marketing-shots.sh` (AGENTS.md, "Marketing screenshots").

Not shown yet: Meet's own Document PiP under Airc's top bar (the demo call opens its Document PiP, which closes at once
in the scripted run; `--script pipcontrols` captures the bar on a test page), and the profile menu itself (a native
menu, which can't be drawn off screen; `profiles.webp` shows profiles through Create Profile instead).

| File | Feature | What it shows | Date | Build |
|---|---|---|---|---|
EOF
  echo "$SHOTS" | while IFS='|' read -r name feature what; do
    if [ -f "$ROOT/assets/screenshots/$name.webp" ]; then
      if echo " $TAKEN " | grep -q " $name "; then when="$DAY"; build="$BUILD_ID"; else
        when="$(grep -E "^\| \`$name.webp\`" "$README" 2>/dev/null | awk -F'|' '{gsub(/ /, "", $5); print $5}' || true)"
        build="$(grep -E "^\| \`$name.webp\`" "$README" 2>/dev/null | awk -F'|' '{sub(/^ /, "", $6); sub(/ $/, "", $6); print $6}' || true)"
      fi
      echo "| \`$name.webp\` | $feature | $what | $when | $build |"
    else
      echo "| — | $feature | Not taken yet: $what | | |"
    fi
  done
} > "$README.new"
mv "$README.new" "$README"
echo "== originals: $ORIGINALS"
echo "== WebP: $ROOT/assets/screenshots ($(ls "$ROOT/assets/screenshots"/*.webp 2>/dev/null | wc -l | tr -d ' ') files)"
grep -E "marketing: (MISSING|pages not settled)|didn't finish" "$ORIGINALS/log.txt" 2>/dev/null || true

#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""What's new: each release's highlights, written once per release.

The app bundles apps/browser/Resources/WhatsNew.json (the sidebar's "Airc 0.1.13 is here" card after an update,
packages/AircKit WhatsNew.swift) and the release's appcast item carries the same lines as <airc:highlights> (the
Restart to Update card, before the restart). Both come from the release notes' "## New since …" section: each
"- **Lead-in.** text" bullet is one line. The card shows a short `title` (at most 26 characters, so it fits one line
in the default 228 pt sidebar): the lead-in shortened by rule ("Your …" dropped, cut at a comma or dash), or the
override in whatsnew-titles.json (lead-in → title), the only way for a lead-in no rule shortens enough. The script
fails if a title is still longer. The lead-in itself is kept as `lead` (VoiceOver, the card's tooltip). The icon is an
SF Symbol picked from the lead-in's words.

whatsnew2: each line also has a `detail` for the "What's new in Airc" tab (Browser/WhatsNewPage.swift): one or two
plain sentences, at most 280 characters, on what the feature does and where to find it, for someone who has never
heard of it. By default it is the bullet's text after the lead-in, cut after its second sentence; a better one goes in
whatsnew-titles.json as an object, `"<lead-in>": {"title": …, "detail": …, "action": …, "image": …}` (every key
optional). `action` is the page's "Show me" button, one of ACTIONS (the app's WhatsNewAction), guessed from the text
when not given, or "none" for a line that deliberately has no button; `image` names a picture in apps/browser/Resources/WhatsNew/ (<name>.heic), guessed from IMAGES. The
script FAILS when a line has no detail.

  whatsnew.py update [--notes docs/release-notes-beta.md] [--section "New since 0.1.12"] VERSION
      adds or replaces VERSION in WhatsNew.json (icons already chosen for the same title are kept, so a hand-picked
      icon survives a rerun). Run it when the notes are written, and commit WhatsNew.json with them.
  whatsnew.py show VERSION       prints VERSION's lines.
  whatsnew.py check              validates WhatsNew.json (the schema the app and tests expect).
"""
import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RESOURCE = ROOT/'apps/browser/Resources/WhatsNew.json'
IMAGE_DIR = ROOT/'apps/browser/Resources/WhatsNew'
TITLES = Path(__file__).resolve().parent/'whatsnew-titles.json'
NOTES = ROOT/'docs/release-notes-beta.md'
SCHEMA = 1
MAX_PER_RELEASE = 7   # wnactions: 7 (was 5); the tab shows all, the sidebar card 5 and "And more"
APPCAST_LINES = 3
TITLE_MAX = 26
LEAD_MAX = 120
DETAIL_MAX = 280
# The app's WhatsNewAction (packages/AircKit WhatsNew.swift): safe in-app actions only. Keep the two lists equal.
ACTIONS = ['commandBar', 'settingsAppIcon', 'settingsSitePreviews', 'settingsAgents', 'settingsSync', 'settingsImport',
           'settingsBoosts', 'settingsGeneral', 'settingsUpdates', 'libraryArchive', 'libraryNotes', 'sendFeedback',
           'settingsAI', 'settingsShortcuts']
# whatsnew-titles.json's `"action": "none"` (or null): this line deliberately has no "Show me" (nothing to open, e.g.
# "Dark mode reads better"). It is never guessed and never written to WhatsNew.json: the line simply has no action.
NO_ACTION = 'none'
# First match wins, on the lead-in and the bullet's text: → the "Show me" action.
ACTION_RULES = [
    (r'app icon', 'settingsAppIcon'),
    (r'site previews|calendar previews|mail previews', 'settingsSitePreviews'),
    (r'settings › agents|\bmcp\b|\bclaude\b', 'settingsAgents'),
    (r'icloud sync|sync between', 'settingsSync'),
    (r'settings › import|arc import|import from arc', 'settingsImport'),
    (r'\bboosts?\b', 'settingsBoosts'),
    (r'\barchive\b', 'libraryArchive'),
    (r'feedback', 'sendFeedback'),
    (r'what.s new', 'settingsUpdates'),
    (r'command bar|⌘t', 'commandBar'),
    (r'settings › ai\b|tidy downloads', 'settingsAI'),
    (r'settings › shortcuts|keyboard shortcuts?', 'settingsShortcuts'),
    (r'settings › general', 'settingsGeneral'),
]
# The lead-in's words → a bundled picture (only if apps/browser/Resources/WhatsNew/<name>.heic exists).
IMAGE_RULES = [
    (r'app icon', 'settings-app-icon'),
    (r'command bar', 'command-bar'),
    (r'split', 'pinned-split'),
    (r'arc import|import', 'arc-import-logins'),
    (r'boost', 'boost-import'),
    (r'feedback', 'send-feedback'),
]
NS = 'https://aircbrowser.com/xml-namespaces/airc'
DEFAULT_ICON = 'sparkles'

# First match wins: a title's words → its SF Symbol (all present in SF Symbols 5, macOS 14).
ICONS = [
    (r'\bspaces?\b.*\bsaved|\bquit', 'externaldrive.badge.checkmark'),
    (r'\bspace\b', 'square.stack.3d.up'),
    (r'right-click|context menu|menus?\b', 'contextualmenu.and.cursorarrow'),
    (r'turn off|\bhide\b', 'eye.slash'),
    (r'extension', 'puzzlepiece.extension'),
    (r'import', 'square.and.arrow.down'),
    (r'held|stuck|drag', 'hand.point.up.left'),
    (r'badge|unread|notification', 'app.badge'),
    (r'search', 'magnifyingglass'),
    (r'easel', 'scribble.variable'),
    (r'feedback', 'bubble.left.and.text.bubble.right'),
    (r'preview.*(age|old)|\bage\b', 'clock'),
    (r'voiceover|accessib', 'accessibility'),
    (r'preview', 'rectangle.on.rectangle'),
    (r'mail|inbox', 'envelope'),
    (r'calendar|meeting', 'calendar'),
    (r'call|camera|microphone', 'video'),
    (r'password|passkey|sign.?in', 'key'),
    (r'download', 'arrow.down.circle'),
    (r'link|copy', 'link'),
    (r'tab', 'square.on.square'),
    (r'split', 'rectangle.split.2x1'),
    (r'boost', 'paintbrush'),
    (r'note', 'note.text'),
    (r'video|music|media|picture in picture', 'play.rectangle'),
    (r'update|what.s new', 'arrow.clockwise'),
    (r'fast|faster|speed|quick', 'bolt'),
    (r'block|ads?\b|privacy|private', 'hand.raised'),
    (r'full.?screen|window', 'macwindow'),
    (r'shortcut|key', 'command'),
]

def icon_for(title):
    t = title.lower()
    for pattern, icon in ICONS:
        if re.search(pattern, t):
            return icon
    return DEFAULT_ICON

def clean_lead(raw):
    """The bold lead-in as plain text: no code marks, no closing period."""
    t = re.sub(r'`([^`]*)`', r'\1', raw).strip()
    return re.sub(r'[.!:]+$', '', t).strip()

def load_titles(path=TITLES):
    return json.loads(path.read_text()) if path.exists() else {}

def short_title(lead, overrides):
    """The card's title for a lead-in: its override, else the lead-in by rule. Raises if over 26 characters."""
    if override(lead, overrides).get('title'):
        t = override(lead, overrides)['title']
    else:
        t = lead
        for sep in (' — ', ' – ', ', ', ': '):
            if len(t) > TITLE_MAX and sep in t:
                t = t.split(sep, 1)[0]
        if len(t) > TITLE_MAX and t.startswith('Your '):
            t = t[5:]
            t = t[:1].upper() + t[1:]
    if not t.strip() or len(t) > TITLE_MAX:
        raise SystemExit(f'title {t!r} for {lead!r} is {len(t)} characters (at most {TITLE_MAX}): '
                         f'add a short title to {TITLES.name}')
    return t

def section(notes_text, heading=None):
    """The lines of the first '## New since …' section (or the named one)."""
    lines, inside = [], False
    for line in notes_text.splitlines():
        if line.startswith('## '):
            name = line[3:].strip()
            if inside:
                break
            inside = (name == heading) if heading else name.lower().startswith('new since')
            continue
        if inside:
            lines.append(line)
    if not inside and not lines:
        raise SystemExit(f'no section {heading or "New since …"} in the notes')
    return lines

def plain(text):
    """Markdown → plain text: no code marks, bold, links or line breaks."""
    t = re.sub(r'`([^`]*)`', r'\1', text)
    t = re.sub(r'\*\*([^*]*)\*\*', r'\1', t)
    t = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', t)
    return re.sub(r'\s+', ' ', t).strip()

def default_detail(body):
    """The bullet's text after the lead-in, cut after its second sentence (and at DETAIL_MAX, on a word)."""
    t = plain(body)
    parts = re.split(r'(?<=[.!?])\s+(?=[A-Z0-9⌘])', t)
    d = ' '.join(parts[:2]).strip()
    if len(d) > DETAIL_MAX:
        d = ' '.join(parts[:1]).strip()
    if len(d) > DETAIL_MAX:
        d = d[:DETAIL_MAX - 1].rsplit(' ', 1)[0].rstrip(',;:') + '…'
    return d

def guess(rules, text):
    t = text.lower()
    for pattern, value in rules:
        if re.search(pattern, t):
            return value
    return None

def override(lead, overrides):
    """An override's fields: a string is the title alone."""
    o = overrides.get(lead)
    return {'title': o} if isinstance(o, str) else dict(o or {})

def bullets(notes_text, heading=None):
    """[(lead-in, text after it)] for the section's '- **Lead-in.** text' bullets (indented continuation lines joined)."""
    out, cur = [], None
    for line in section(notes_text, heading):
        m = re.match(r'- \*\*(.+?)\*\*(.*)', line)
        if m:
            cur = [m[1], m[2]]
            out.append(cur)
        elif cur is not None and line.startswith('  ') and line.strip():
            cur[1] += ' ' + line.strip()
        else:
            cur = None   # a blank or other line ends the bullet
    return [tuple(b) for b in out]

def extract(notes_text, heading=None, keep=None, overrides=None, image_dir=None):
    """[{title, lead, detail, icon, action?, image?}] from the section's '- **Lead-in.** …' bullets, at most seven.
    `keep`: lead-in → icon to reuse (a hand-picked icon survives a rerun); `overrides`: lead-in → short title or
    {title, detail, action, image} (whatsnew-titles.json). Fails when a line ends up without a detail."""
    keep = keep or {}
    overrides = load_titles() if overrides is None else overrides
    image_dir = IMAGE_DIR if image_dir is None else image_dir
    out = []
    for raw, body in bullets(notes_text, heading):
        lead = clean_lead(raw)
        if not lead or lead.lower() in (h['lead'].lower() for h in out):
            continue
        o = override(lead, overrides)
        h = {'title': o.get('title') or short_title(lead, {}), 'lead': lead[:LEAD_MAX],
             'detail': o.get('detail') or default_detail(body)}
        h['icon'] = keep.get(lead) or keep.get(lead.lower()) or keep.get(h['title'].lower()) or icon_for(lead)
        if len(h['title']) > TITLE_MAX:
            short_title(lead, {lead: h['title']})   # raises with the fix
        if not h['detail']:
            raise SystemExit(f'{lead!r} has no detail: its bullet has no text after the lead-in. Add '
                             f'"{lead}": {{"detail": "…"}} to {TITLES.name}')
        action = o.get('action', guess(ACTION_RULES, lead + ' ' + body))
        if action is not None and action != NO_ACTION and action not in ACTIONS:
            raise SystemExit(f'{lead!r}: action {action!r} in {TITLES.name} is not one of {", ".join(ACTIONS)}, '
                             f'or "{NO_ACTION}" for no Show me')
        if action and action != NO_ACTION:
            h['action'] = action
        image = o.get('image', guess(IMAGE_RULES, lead))
        if image and (Path(image_dir)/f'{image}.heic').exists():
            h['image'] = image
        out.append(h)
        if len(out) == MAX_PER_RELEASE:
            break
    if not out:
        raise SystemExit('the section has no "- **Title.**" bullets')
    return out

def version_key(v):
    return tuple(int(x) for x in v.split('.'))

def load(path=RESOURCE):
    if not path.exists():
        return {'schema': SCHEMA, 'releases': []}
    return json.loads(path.read_text())

# Releases before the What's new tab (0.1.13) were written without details; every later one must have them.
DETAIL_SINCE = (0, 1, 13)

def require_detail(v):
    try:
        return version_key(v) >= DETAIL_SINCE
    except ValueError:
        return True

def validate(doc, check_images=True):
    errors = []
    if doc.get('schema') != SCHEMA:
        errors.append(f'schema {doc.get("schema")!r}, expected {SCHEMA}')
    seen = set()
    for r in doc.get('releases', []):
        v = r.get('version', '')
        if not re.fullmatch(r'\d+\.\d+\.\d+', v): errors.append(f'version {v!r}')
        if v in seen: errors.append(f'{v} twice')
        seen.add(v)
        hs = r.get('highlights', [])
        if not 1 <= len(hs) <= MAX_PER_RELEASE: errors.append(f'{v}: {len(hs)} highlights')
        for h in hs:
            t = h.get('title', '')
            if not t.strip() or len(t) > TITLE_MAX or '\n' in t: errors.append(f'{v}: title {t!r} ({len(t)} characters, at most {TITLE_MAX})')
            l = h.get('lead')
            if l is not None and (not l.strip() or len(l) > LEAD_MAX or '\n' in l): errors.append(f'{v}: lead {l!r}')
            d = h.get('detail')
            if d is not None and (not d.strip() or len(d) > DETAIL_MAX or '\n' in d): errors.append(f'{v}: detail {d!r} ({len(d or "")} characters, at most {DETAIL_MAX})')
            if require_detail(v) and not d: errors.append(f'{v}: {t!r} has no detail')
            if not re.fullmatch(r'[a-z0-9]+(\.[a-z0-9]+)*', h.get('icon', '')): errors.append(f'{v}: icon {h.get("icon")!r}')
            a = h.get('action')
            if a is not None and a not in ACTIONS: errors.append(f'{v}: action {a!r} (one of {", ".join(ACTIONS)})')
            i = h.get('image')
            if i is not None and (not re.fullmatch(r'[a-z0-9]+(-[a-z0-9]+)*', i) or (check_images and not (IMAGE_DIR/f'{i}.heic').exists())):
                errors.append(f'{v}: image {i!r} (no {i}.heic in {IMAGE_DIR.name}/)')
            if set(h) - {'title', 'lead', 'detail', 'icon', 'anchor', 'action', 'image'}: errors.append(f'{v}: keys {sorted(h)}')
    return errors

def write(doc, path=RESOURCE):
    doc['releases'].sort(key=lambda r: version_key(r['version']), reverse=True)
    errors = validate(doc)
    if errors:
        raise SystemExit('WhatsNew.json invalid: ' + '; '.join(errors))
    tmp = path.with_suffix('.json.tmp')
    tmp.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + '\n')
    tmp.replace(path)

def update(version, notes_text, heading=None, path=RESOURCE):
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise SystemExit(f'version {version!r} is not x.y.z')
    doc = load(path)
    keep = {h.get('lead', h['title']): h['icon'] for r in doc['releases'] for h in r['highlights']}
    lines = extract(notes_text, heading, keep)
    doc['releases'] = [r for r in doc['releases'] if r['version'] != version] + [{'version': version, 'highlights': lines}]
    write(doc, path)
    return lines

def icons_by_line(docs):
    """lead-in (or title) → icon from WhatsNew.json docs, earlier docs and newer releases first: the hand-picked icons."""
    icons = {}
    for doc in docs:
        for r in sorted(doc.get('releases', []), key=lambda r: version_key(r['version']), reverse=True):
            for h in r.get('highlights', []):
                for key in (h.get('lead'), h.get('title')):
                    if key and h.get('icon'):
                        icons.setdefault(key.lower(), h['icon'])
    return icons

def appcast_lines(version, notes_text=None, resources=()):
    """The appcast item's highlights. `resources`: WhatsNew.json paths, most authoritative first (the staged app's,
    then the tooling tree's). The release's entry in the first one that has it wins. Without an entry, the lines come
    from the notes' section, each with the icon a WhatsNew.json line with the same lead-in or title has (promptic,
    after 0.1.17 shipped guessed icons); icon_for's guess is only for lines no WhatsNew.json has."""
    if isinstance(resources, (str, Path)):
        resources = [resources]
    docs = [json.loads(Path(p).read_text()) for p in resources if p and Path(p).exists()]
    for doc in docs:
        for r in doc.get('releases', []):
            if r.get('version') == version:
                return [appcast_line(h) for h in r['highlights'][:APPCAST_LINES]]
    if notes_text is None:
        return []
    try:
        return [appcast_line(h) for h in extract(notes_text, keep=icons_by_line(docs))[:APPCAST_LINES]]
    except SystemExit:
        return []

def appcast_line(h):
    """One Restart to Update line: title, lead-in and icon. `detail` carries the lead-in too, as 0.1.13–0.1.15 read
    it for VoiceOver (the page's longer detail isn't needed before the restart)."""
    lead = h.get('lead') or h.get('detail') or h['title']
    return {'title': h['title'], 'lead': lead, 'detail': lead, 'icon': h['icon']}

def appcast_text(lines):
    return json.dumps(lines, ensure_ascii=False, separators=(',', ':'))

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    u = sub.add_parser('update'); u.add_argument('version'); u.add_argument('--notes', default=str(NOTES)); u.add_argument('--section')
    s = sub.add_parser('show'); s.add_argument('version')
    sub.add_parser('check')
    a = ap.parse_args()
    if a.cmd == 'update':
        for h in update(a.version, Path(a.notes).read_text(), a.section):
            print(f'{a.version}  {h["icon"]:32} {h["title"]:28} {h.get("action", "-"):22} {h.get("image", "-")}\n    {h["detail"]}')
    elif a.cmd == 'show':
        for r in load()['releases']:
            if r['version'] == a.version:
                for h in r['highlights']:
                    print(f'{h["icon"]:34} {h["title"]:28} {h.get("action", "-"):22} {h.get("image", "-")}\n    {h.get("detail", "(no detail)")}')
                return
        raise SystemExit(f'{a.version} not in WhatsNew.json')
    else:
        errors = validate(load())
        if errors: raise SystemExit('\n'.join(errors))
        print(f'WhatsNew.json OK: {len(load()["releases"])} releases')

if __name__ == '__main__':
    main()

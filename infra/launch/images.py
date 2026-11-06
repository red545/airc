#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Image review sheet for an exported tree: every committed image, its size, where it is used,
what text it shows (OCR) and anything that looks personal. Writes one self-contained HTML page
with downscaled thumbnails, so the owner can approve every image in a few minutes.

    images.py <dir> <out.html> [--patterns FILE] [--json FILE]

Needs Pillow for thumbnails. OCR uses the `tesseract` command when installed, else RapidOCR
when importable, else it is skipped and the sheet says so. Flags never print private values:
matches from the private pattern file show as their kind only, and are redacted from OCR text.
"""
import argparse
import base64
import datetime
import html
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

EXTENSIONS = {'.png', '.jpg', '.jpeg', '.webp', '.gif', '.icns', '.svg'}
TEXT_EXTENSIONS = {'.md', '.swift', '.py', '.sh', '.js', '.mjs', '.ts', '.astro', '.html', '.css', '.json',
                   '.plist', '.txt', '.mm', '.m', '.cc', '.h', '.yml', '.yaml', '.toml', '.svg', '.inc'}
THUMB = 360
EMAIL = re.compile(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}')
HANDLE = re.compile(r'(?<![\w@])@[A-Za-z][\w-]{2,}')
HOSTLIKE = re.compile(r'(?i)\b(?:[a-z0-9-]+\.)+(?:com|net|org|io|dev|app|ts\.net|local|internal|lan|co|me|ai)\b(?::\d+)?(?:/\S*)?')
LOCALURL = re.compile(r'(?i)\b(?:localhost|127\.0\.0\.1)(?::\d+)?\S*')
NAME = re.compile(r'\b([A-Z][a-z]{2,})\s+([A-Z][a-z]{2,})\b')
RESERVED = re.compile(r'(?i)@(?:[\w-]+\.)*(?:example\.(?:com|net|org)|example|invalid|test|localhost)$')
# Hosts that are expected on screen in a browser's own marketing shots.
PUBLIC_HOSTS = re.compile(r'(?i)\b(?:aircbrowser\.com|arc\.net|github\.com|google\.com|gmail\.com|youtube\.com|'
                          r'wikipedia\.org|example\.(?:com|net|org)|apple\.com|figma\.com|notion\.so|vercel\.com)\b')


def load_patterns(path):
    patterns = []
    if not path or not Path(path).is_file():
        return patterns
    for line in Path(path).read_text(encoding='utf8').splitlines():
        if not line.strip() or line.startswith('#') or '\t' not in line:
            continue
        kind, spec = line.split('\t', 1)
        mode, _, value = spec.partition(':')
        if mode == 'literal':
            patterns.append((kind, re.compile(r'(?<![A-Za-z0-9])' + re.escape(value) + r'(?![A-Za-z0-9])', re.I)))
        elif mode == 'regex':
            patterns.append((kind, re.compile(value)))
    return patterns


def text_files(root):
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in ('.git', 'node_modules')]
        for name in files:
            path = Path(base) / name
            if path.suffix.lower() in TEXT_EXTENSIONS or name in ('README', 'NOTICE', 'LICENSE'):
                try:
                    yield path, path.read_text(encoding='utf8')
                except (UnicodeDecodeError, OSError):
                    pass


def ocr_engine():
    if shutil.which('tesseract'):
        return 'tesseract'
    try:
        from rapidocr_onnxruntime import RapidOCR  # noqa: F401
        return 'rapidocr'
    except ImportError:
        return None


_rapid = None


def ocr(engine, image):
    """Text lines from a Pillow image (RGB)."""
    global _rapid
    if engine == 'tesseract':
        buf = io.BytesIO()
        image.save(buf, 'PNG')
        out = subprocess.run(['tesseract', '-', '-', '--psm', '3'], input=buf.getvalue(), capture_output=True)
        return [l.strip() for l in out.stdout.decode('utf8', 'replace').splitlines() if l.strip()]
    if engine == 'rapidocr':
        import numpy
        from rapidocr_onnxruntime import RapidOCR
        _rapid = _rapid or RapidOCR()
        result, _ = _rapid(numpy.array(image))
        return [r[1].strip() for r in (result or []) if r[1].strip()]
    return []


def redact(text, patterns):
    kinds = set()
    for kind, rx in patterns:
        if rx.search(text):
            kinds.add(kind)
            text = rx.sub(f'[private:{kind}]', text)
    return text, kinds


def flags_for_text(lines, patterns, vocabulary, public_emails):
    flags = []
    shown = []
    for line in lines:
        line, kinds = redact(line, patterns)
        shown.append(line)
        flags += [f'private value ({k})' for k in sorted(kinds)]
        for m in EMAIL.finditer(line):
            if not RESERVED.search(m.group(0)) and m.group(0).lower() not in public_emails:
                flags.append('email address')
        for m in HANDLE.finditer(line):
            flags.append(f'account handle "{m.group(0)}"')
        for m in LOCALURL.finditer(line):
            flags.append(f'local URL "{m.group(0)}"')
        for m in HOSTLIKE.finditer(line):
            if not PUBLIC_HOSTS.search(m.group(0)) and '@' not in line[max(0, m.start() - 1):m.start()]:
                flags.append(f'URL/host "{m.group(0)}"')
        for m in NAME.finditer(line):
            a, b = m.group(1), m.group(2)
            if a.lower() not in vocabulary and b.lower() not in vocabulary:
                flags.append(f'possible personal name "{a} {b}"')
    return flags, shown


def open_raster(path):
    from PIL import Image
    image = Image.open(path)  # .icns opens at its largest representation
    if getattr(image, 'n_frames', 1) > 1:
        image.seek(0)
    return image


BENIGN_EXIF = {'ResolutionUnit', 'XResolution', 'YResolution', 'ExifOffset', 'Orientation', 'ColorSpace',
               'ExifImageWidth', 'ExifImageHeight', 'PixelXDimension', 'PixelYDimension'}
BENIGN_XMP = {'x:xmpmeta', 'rdf:RDF', 'rdf:Description', 'exif:ColorSpace', 'exif:PixelXDimension',
              'exif:PixelYDimension', 'tiff:ResolutionUnit', 'tiff:XResolution', 'tiff:YResolution', 'tiff:Orientation'}
BENIGN_INFO = {'dpi', 'gamma', 'srgb', 'icc_profile', 'transparency', 'aspect', 'chromaticity', 'sizes', 'loop',
               'duration', 'background', 'interlace', 'progressive', 'progression', 'jfif', 'jfif_version',
               'jfif_unit', 'jfif_density', 'adobe', 'adobe_transform', 'compression', 'lossless', 'bitmap',
               'version', 'exif', 'xmp', 'xml:com.adobe.xmp', 'blend', 'disposal', 'timestamp'}


def metadata_flags(path, image):
    """Flag metadata that could carry personal data; resolution and colour-space tags are fine."""
    from PIL import ExifTags
    flags = []
    names = set()
    exif = image.getexif()
    for tag in exif:
        names.add(ExifTags.TAGS.get(tag, str(tag)))
    for ifd in (ExifTags.IFD.Exif, ExifTags.IFD.GPSInfo):
        try:
            names |= {(ExifTags.GPSTAGS if ifd == ExifTags.IFD.GPSInfo else ExifTags.TAGS).get(t, str(t))
                      for t in exif.get_ifd(ifd)}
        except Exception:
            pass
    odd = sorted(names - BENIGN_EXIF)
    if odd:
        flags.append('EXIF tags: ' + ', '.join(odd[:12]))
    xmp = image.info.get('XML:com.adobe.xmp') or image.info.get('xmp') or ''
    if isinstance(xmp, bytes):
        xmp = xmp.decode('utf8', 'replace')
    odd = sorted(set(re.findall(r'<([A-Za-z]+:[A-Za-z]+)[\s/>]', xmp)) - BENIGN_XMP)
    if odd:
        flags.append('XMP tags: ' + ', '.join(odd[:12]))
    extra = sorted(str(k) for k in image.info if str(k).lower() not in BENIGN_INFO)
    if extra:
        flags.append('embedded text chunks: ' + ', '.join(extra[:12]))
    return flags


def unknown_words(lines, vocabulary):
    """OCR words (4+ letters) that appear in no committed text file: the ones worth a look."""
    words = []
    for line in lines:
        for w in re.findall(r'[A-Za-z]{4,}', line):
            if w.lower() not in vocabulary and w not in words:
                words.append(w)
    return words


def svg_info(text):
    flags = []
    if re.search(r'<image\b|data:image/', text):
        flags.append('SVG embeds a raster image')
    if re.search(r'sodipodi:docname|inkscape:export-filename|<metadata\b|<rdf:', text):
        flags.append('SVG editor metadata present')
    words = [html.unescape(re.sub(r'<[^>]+>', '', t)).strip() for t in re.findall(r'<text\b[^>]*>(.*?)</text>', text, re.S)]
    return flags, [w for w in words if w]


def thumbnail(image):
    from PIL import Image
    image = image.convert('RGBA')
    image.thumbnail((THUMB, THUMB), Image.LANCZOS)
    buf = io.BytesIO()
    image.save(buf, 'WEBP', quality=72, method=6)
    return 'data:image/webp;base64,' + base64.b64encode(buf.getvalue()).decode()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('dir')
    ap.add_argument('out')
    ap.add_argument('--patterns')
    ap.add_argument('--json')
    args = ap.parse_args()
    root = Path(args.dir).resolve()
    patterns = load_patterns(args.patterns)
    try:
        import PIL  # noqa: F401
        have_pil = True
    except ImportError:
        have_pil = False
    engine = ocr_engine() if have_pil else None

    texts = list(text_files(root))
    vocabulary = set()
    for _, text in texts:
        vocabulary.update(w.lower() for w in re.findall(r'[A-Za-z]{3,}', text))
    public_emails = set()
    site = root / 'apps/marketing/src/lib/site.ts'
    if site.is_file():
        public_emails = {e.lower() for e in re.findall(r'EMAIL\w*\s*=\s*"([^"]+@[^"]+)"', site.read_text())}

    images = sorted(p for p in root.rglob('*') if p.suffix.lower() in EXTENSIONS and p.is_file()
                    and '.git' not in p.relative_to(root).parts and 'node_modules' not in p.parts)
    entries = []
    for path in images:
        rel = path.relative_to(root).as_posix()
        entry = {'path': rel, 'bytes': path.stat().st_size, 'format': path.suffix.lower().lstrip('.'),
                 'refs': [], 'flags': [], 'ocr': [], 'unknown': [], 'thumb': None, 'size': None}
        # Where it is used: any text file naming the file (by name), with line numbers.
        for tpath, text in texts:
            if tpath == path:
                continue
            for number, line in enumerate(text.splitlines(), 1):
                if path.name in line:
                    entry['refs'].append(f'{tpath.relative_to(root).as_posix()}:{number}')
        if path.suffix.lower() == '.svg':
            svg = path.read_text(encoding='utf8', errors='replace')
            flags, words = svg_info(svg)
            entry['flags'] += flags
            if words:
                more, shown = flags_for_text(words, patterns, vocabulary, public_emails)
                entry['flags'] += more
                entry['ocr'] = ['(SVG text) ' + w for w in shown]
            entry['thumb'] = 'data:image/svg+xml;base64,' + base64.b64encode(svg.encode()).decode()
            m = re.search(r'viewBox="[\d.\s-]*?([\d.]+)\s+([\d.]+)"', svg)
            entry['size'] = f'{m.group(1)}×{m.group(2)} (viewBox)' if m else 'vector'
        elif have_pil:
            try:
                image = open_raster(path)
                entry['size'] = f'{image.size[0]}×{image.size[1]}'
                entry['flags'] += metadata_flags(path, image)
                rgb = image.convert('RGBA')
                entry['thumb'] = thumbnail(rgb)
                if engine and min(rgb.size) >= 48:
                    # OCR on white for transparent art; upscale small images so text is readable.
                    from PIL import Image
                    flat = Image.new('RGB', rgb.size, 'white')
                    flat.paste(rgb, mask=rgb.split()[3])
                    if max(flat.size) < 1000:
                        factor = max(1, 1000 // max(flat.size))
                        flat = flat.resize((flat.size[0] * factor, flat.size[1] * factor))
                    lines = ocr(engine, flat)
                    flags, shown = flags_for_text(lines, patterns, vocabulary, public_emails)
                    entry['flags'] += flags
                    entry['ocr'] = shown
                    entry['unknown'] = unknown_words(shown, vocabulary)
            except Exception as error:  # an unreadable image must still show up on the sheet
                entry['flags'].append(f'could not decode: {type(error).__name__}')
        if not entry['refs']:
            entry['flags'].append('not referenced by name in any text file')
        entry['flags'] = sorted(set(entry['flags']), key=entry['flags'].index)
        entries.append(entry)

    ocr_note = {'tesseract': 'OCR: tesseract', 'rapidocr': 'OCR: RapidOCR (tesseract is not installed)',
                None: 'OCR: not run (no tesseract, no RapidOCR' + ('' if have_pil else ', no Pillow') + ')'}[engine]
    write_html(Path(args.out), entries, ocr_note, root)
    if args.json:
        Path(args.json).write_text(json.dumps([{k: v for k, v in e.items() if k != 'thumb'} for e in entries], indent=1))
    flagged = sum(1 for e in entries if is_flagged(e))
    print(f'{len(entries)} images, {flagged} with flags; {ocr_note}; wrote {args.out} '
          f'({Path(args.out).stat().st_size // 1024} KB)')


def is_flagged(entry):
    return any(not f.startswith('not referenced') for f in entry['flags'])


def write_html(out, entries, ocr_note, root):
    def card(i, e):
        flags = ''.join(f'<li class="{"warn" if not f.startswith("not referenced") else "note"}">{html.escape(f)}</li>'
                        for f in e['flags']) or '<li class="ok">no flags</li>'
        refs = e['refs'][:6]
        more = f' and {len(e["refs"]) - 6} more' if len(e['refs']) > 6 else ''
        refs_html = ('<br>'.join(html.escape(r) for r in refs) + html.escape(more)) or '<i>none</i>'
        ocr_html = ''
        if e['ocr']:
            ocr_html += ('<div class="refs"><b>Seen text not in any committed file:</b> '
                         + (html.escape(', '.join(e['unknown'][:40])) or '<i>none (all words appear in the tree)</i>')
                         + '</div>')
            ocr_html += (f'<details><summary>Text seen ({len(e["ocr"])} lines)</summary><pre>'
                        + html.escape('\n'.join(e['ocr'])) + '</pre></details>')
        img = f'<img loading="lazy" src="{e["thumb"]}" alt="">' if e['thumb'] else '<div class="noimg">no preview</div>'
        cls = 'card flagged' if is_flagged(e) else 'card'
        return f'''<div class="{cls}" id="c{i}">
  <div class="thumb">{img}</div>
  <label class="approve"><input type="checkbox" data-path="{html.escape(e['path'])}"> approve</label>
  <div class="path">{html.escape(e['path'])}</div>
  <div class="meta">{html.escape(e['format'])} · {e['size'] or '?'} · {e['bytes'] / 1024:.1f} KB</div>
  <ul class="flags">{flags}</ul>
  <div class="refs"><b>Used in:</b><br>{refs_html}</div>
  {ocr_html}
</div>'''

    flagged = sum(1 for e in entries if is_flagged(e))
    body = '\n'.join(card(i, e) for i, e in enumerate(entries))
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d %H:%M UTC')
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Airc public repo: image review</title>
<style>
:root {{ color-scheme: light dark; --bg:#f6f6f4; --fg:#1d1d1f; --card:#fff; --mute:#6e6e73; --line:#e3e3e0; --warn:#b3261e; --ok:#1b7f3b; }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg:#1c1c1e; --fg:#f2f2f7; --card:#2c2c2e; --mute:#a1a1a6; --line:#3a3a3c; --warn:#ff8a80; --ok:#7ee2a0; }} }}
body {{ font: 14px/1.4 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 24px; background: var(--bg); color: var(--fg); }}
h1 {{ font-size: 20px; margin: 0 0 4px; }} .sub {{ color: var(--mute); margin-bottom: 16px; }}
.bar {{ position: sticky; top: 0; background: var(--bg); padding: 8px 0; z-index: 1; display: flex; gap: 16px; align-items: center; flex-wrap: wrap; }}
.grid {{ display: grid; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); gap: 14px; }}
.card {{ background: var(--card); border: 1px solid var(--line); border-radius: 10px; padding: 10px; }}
.card.flagged {{ border-color: var(--warn); }}
.card.done {{ opacity: .55; }}
.thumb {{ height: 200px; display: flex; align-items: center; justify-content: center; border-radius: 6px;
  background: repeating-conic-gradient(#ccc 0 25%, #fff 0 50%) 0 0/16px 16px; overflow: hidden; }}
.thumb img {{ max-width: 100%; max-height: 200px; }}
.path {{ font: 12px ui-monospace, Menlo, monospace; word-break: break-all; margin-top: 8px; }}
.meta, .refs {{ color: var(--mute); font-size: 12px; margin-top: 4px; }}
.refs {{ font-family: ui-monospace, Menlo, monospace; word-break: break-all; }}
.flags {{ margin: 6px 0 0; padding-left: 18px; font-size: 12px; }}
.flags .warn {{ color: var(--warn); }} .flags .ok {{ color: var(--ok); }} .flags .note {{ color: var(--mute); }}
.approve {{ float: right; margin-top: 8px; font-size: 12px; }}
pre {{ white-space: pre-wrap; font-size: 11px; max-height: 200px; overflow: auto; }}
details summary {{ cursor: pointer; font-size: 12px; margin-top: 6px; }}
textarea {{ width: 100%; height: 80px; font: 11px ui-monospace, monospace; }}
</style></head><body>
<h1>Airc public repo: image review</h1>
<div class="sub">{len(entries)} committed images from the exported tree · {flagged} flagged · {html.escape(ocr_note)} · generated {stamp}.
Thumbnails are downscaled. Tick each image you approve for publishing; ticks are saved in this browser. Then copy the list below into the launch notes.</div>
<div class="bar"><label><input type="checkbox" id="onlyflagged"> show flagged only</label><span id="count"></span></div>
<div class="grid">
{body}
</div>
<h2 style="font-size:16px">Approved list</h2>
<textarea id="approved" readonly></textarea>
<script>
const KEY = 'airc-image-review';
const saved = JSON.parse(localStorage.getItem(KEY) || '{{}}');
const boxes = [...document.querySelectorAll('.approve input')];
function update() {{
  const ok = boxes.filter(b => b.checked).map(b => b.dataset.path);
  document.getElementById('count').textContent = ok.length + ' of ' + boxes.length + ' approved';
  document.getElementById('approved').value = ok.map(p => 'approved\\t' + p).join('\\n');
  boxes.forEach(b => b.closest('.card').classList.toggle('done', b.checked));
}}
boxes.forEach(b => {{ b.checked = !!saved[b.dataset.path]; b.addEventListener('change', () => {{
  saved[b.dataset.path] = b.checked; localStorage.setItem(KEY, JSON.stringify(saved)); update(); }}); }});
document.getElementById('onlyflagged').addEventListener('change', e => {{
  document.querySelectorAll('.card').forEach(c => c.style.display = e.target.checked && !c.classList.contains('flagged') ? 'none' : ''); }});
update();
</script>
</body></html>
''', encoding='utf8')


if __name__ == '__main__':
    sys.exit(main())

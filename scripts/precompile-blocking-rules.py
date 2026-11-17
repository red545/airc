#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Compile the default blocking lists into a WebKit content rule list at build time (wkrules).

    precompile-blocking-rules.py AIRC_EXECUTABLE OUT_DIR

A fresh profile blocks with the bundled EasyList + EasyPrivacy seeds. On the WebKit engine those must be compiled into a
WKContentRuleList (~4.4 s) before its first page may load, so the first launch ever painted a link after ~4.3 s. This
compiles exactly that list once, with the app's own compile child (`Airc --airc-compile-content-rules`, the same
converter and WebKit the app uses), and writes OUT_DIR/rules.json plus the store file, LZFSE-compressed. build-app.sh
copies OUT_DIR into Contents/Resources/BlockingRules; WebKitBlocking (BundledRuleLists) expands it into the profile's
store on first use and falls back to compiling when this WebKit can't read it.

The identifier must be the one the app computes: WebKitBlocking's prefix + SHA-256 of the selected lists' text joined
by "\\n" in id order (BlockingListStore.text(for:)). The result is cached in OUT_DIR/../rules-store-cache by the list
bytes, the converter library and the WebKit version.
"""
import hashlib, json, os, pathlib, re, shutil, subprocess, sys, tempfile

root = pathlib.Path(__file__).resolve().parent.parent
binary, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
seeds = root / 'apps/browser/Resources/BlockingLists'
swift = (root / 'apps/browser/Sources/Airc/Engine/WebKitEngine+Blocking.swift').read_text()
m = re.search(r'private static let prefix = "(airc-blocking-v\d+-)"', swift)
if not m: sys.exit('precompile-blocking-rules: WebKitBlocking.prefix not found')
parts = []
for name in sorted(['easylist', 'easyprivacy']):   # the defaults (BlockingSettings), sorted as text(for:) joins them
    data = (seeds / f'{name}.txt').read_bytes()
    # Swift reads the text with String(data:encoding: .utf8) and digests Data(text.utf8): the same bytes only for
    # BOM-less valid UTF-8.
    if data.startswith(b'\xef\xbb\xbf'): sys.exit(f'precompile-blocking-rules: {name}.txt starts with a BOM')
    data.decode('utf-8')
    parts.append(data)
text = b'\n'.join(parts)
identifier = m.group(1) + hashlib.sha256(text).hexdigest()

library = root / 'build/blocking/target/release/libairc_blocking.a'
webkit = subprocess.run(['/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleVersion',
                         '/System/Library/Frameworks/WebKit.framework/Resources/Info.plist'],
                        capture_output=True, text=True).stdout.strip()
macos = subprocess.run(['sw_vers', '-buildVersion'], capture_output=True, text=True).stdout.strip()
key = hashlib.sha256('\0'.join([identifier, hashlib.sha256(library.read_bytes()).hexdigest() if library.exists() else '',
                                webkit, macos]).encode()).hexdigest()[:24]
cache = out.parent / 'rules-store-cache' / key
if not (cache / 'rules.json').exists():
    with tempfile.TemporaryDirectory(dir=out.parent) as tmp:
        tmp = pathlib.Path(tmp)
        (tmp / 'store').mkdir()
        (tmp / 'lists.txt').write_bytes(text)
        # The unbundled executable: a release build links Sparkle from @executable_path/../Frameworks, so point dyld at it.
        env = dict(os.environ)
        if os.environ.get('SPARKLE_ROOT'): env['DYLD_FRAMEWORK_PATH'] = os.environ['SPARKLE_ROOT']
        r = subprocess.run([str(binary), '--airc-compile-content-rules', str(tmp / 'store'), identifier, str(tmp / 'lists.txt')],
                           stdin=subprocess.DEVNULL, capture_output=True, timeout=300, env=env)
        compiled = tmp / 'store' / f'ContentRuleList-{identifier}'
        if r.returncode != 0 or not compiled.is_file():
            sys.exit(f'precompile-blocking-rules: compile failed (exit {r.returncode}): {r.stderr.decode()[-400:]}')
        raw = compiled.read_bytes()
        name = identifier + '.lzfse'
        subprocess.run(['compression_tool', '-encode', '-a', 'lzfse', '-i', str(compiled), '-o', str(tmp / name)], check=True)
        manifest = {'schema': 1, 'lists': [{
            'identifier': identifier, 'file': name, 'size': len(raw), 'sha256': hashlib.sha256(raw).hexdigest(),
            'webkitFileVersion': int.from_bytes(raw[:4], 'little'), 'webkit': webkit, 'macOS': macos,
            'lists': ['easylist', 'easyprivacy']}]}
        (tmp / 'rules.json').write_text(json.dumps(manifest, indent=1, sort_keys=True) + '\n')
        stage = tmp / 'out'; stage.mkdir()
        shutil.move(str(tmp / name), stage / name); shutil.move(str(tmp / 'rules.json'), stage / 'rules.json')
        cache.parent.mkdir(parents=True, exist_ok=True)
        shutil.rmtree(cache, ignore_errors=True)
        shutil.move(str(stage), cache)
    # Only the newest few cache entries are kept.
    for old in sorted(cache.parent.iterdir(), key=lambda p: p.stat().st_mtime)[:-3]: shutil.rmtree(old, ignore_errors=True)
shutil.rmtree(out, ignore_errors=True)
shutil.copytree(cache, out)
entry = json.loads((out / 'rules.json').read_text())['lists'][0]
print(f"  compiled rule list {entry['identifier'][:32]}…: {entry['size'] / 1e6:.1f} MB, "
      f"{(out / entry['file']).stat().st_size / 1e6:.1f} MB bundled, WebKit {entry['webkit']} format {entry['webkitFileVersion']}")

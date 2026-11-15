#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Give the engine's helper apps the app's own bundle identifier, as Chrome does.

Chrome's helpers are com.google.Chrome.helper and com.google.Chrome.helper.renderer, Arc's are
company.thebrowser.browser.helper: '<app id>.helper[.suffix]'. The framework is built once for every channel, so
its helpers come out as org.airc.browser.helper*, a name that maps to no app. Call recorders and meeting-notes
apps (artifacts/callrecorders/REPORT.md) see microphone use per process through CoreAudio, where Chromium's
audio service runs in 'Airc Helper', and map '<app>.helper' to the app. Run this before signing, whenever the
app's identifier is final (scripts/release/sign.py, engine/embed-framework.sh). Idempotent.

Only '.helper' identifiers change. The Alerts XPC service keeps its identifier: macOS keys notification
permission to it. Chromium checks a child's team identity, never its bundle identifier, so nothing at runtime
reads these names.
"""
import pathlib
import plistlib
import sys


def helper_id(app_id, current):
    """'<app id>.helper[.suffix]' for a helper identifier, or None for anything that isn't a helper's."""
    at = current.find('.helper')
    if at < 0 or (len(current) > at + 7 and current[at + 7] != '.'):
        return None
    return app_id + current[at:]


def follow_app(app):
    """Rewrites each helper's CFBundleIdentifier in an unsigned (or about to be re-signed) app; returns the changes."""
    app = pathlib.Path(app)
    app_id = plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier']
    changed = []
    for framework in sorted((app / 'Contents/Frameworks').glob('*.framework')):
        versions = framework / 'Versions'
        if not versions.is_dir():
            continue
        for version in sorted(versions.iterdir()):
            if version.is_symlink() or not version.is_dir():
                continue
            for helper in sorted((version / 'Helpers').glob('*.app')):
                plist = helper / 'Contents/Info.plist'
                if helper.is_symlink() or not plist.is_file():
                    continue
                info = plistlib.loads(plist.read_bytes())
                old = info.get('CFBundleIdentifier', '')
                new = helper_id(app_id, old)
                if new and new != old:
                    info['CFBundleIdentifier'] = new
                    plist.write_bytes(plistlib.dumps(info))
                    changed.append((helper.name, old, new))
    return changed


if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit('Usage: helper_ids.py APP')
    for name, old, new in follow_app(sys.argv[1]):
        print(f'{name}: {old} -> {new}')

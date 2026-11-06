# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

"""Optional, escaped status section; a broken poll must not break nightly status."""
import html
import json
from datetime import datetime, timezone
from pathlib import Path


def render():
    try:
        s = json.loads(Path(__file__).with_name('state.json').read_text())
        stale = (datetime.now(timezone.utc) - datetime.fromisoformat(s['checked'])).total_seconds() > 7 * 3600
        fields = {'Pinned': s['pinned'], 'Extended Stable': s.get('extended', 'unknown'),
                  'Stable (information only)': s.get('stable', 'unknown'), 'Gap': s.get('gap', 'unknown'),
                  'Security': s.get('security', {}).get('urgency', 'unknown'),
                  'Poll': s.get('error') or ('STALE' if stale else 'OK'), 'Checked': s['checked']}
        return '<table>' + ''.join(f'<tr><td>{html.escape(k)}</td><td>{html.escape(str(v))}</td></tr>' for k, v in fields.items()) + '</table>'
    except Exception:
        return '<p>Chromium release state unavailable. Run infra/chromium/watch.py.</p>'

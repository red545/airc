#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Read-only persistence checks for the synthetic autofill scenario's scratch root."""
import json
from pathlib import Path
import sqlite3
import sys
root = Path(sys.argv[1]).resolve()
report = json.loads((root / 'autofill.json').read_text())
assert report['ok'] and report['profiles']['addressPrompt']['kind'] == 'saveAddress'
assert report['profiles']['cardPrompt']['kind'] == 'saveCard'
result = {}
for name, expected in [('Profile One', 1), ('Profile Two', 0)]:
    file = root / 'Chromium' / name / 'Web Data'
    with sqlite3.connect(file.as_uri() + '?mode=ro', uri=True) as db:
        addresses = db.execute('SELECT count(*) FROM addresses').fetchone()[0]
        cards = db.execute('SELECT card_number_encrypted FROM credit_cards').fetchall()
    assert addresses == expected and len(cards) == expected, (name, addresses, len(cards))
    assert all(row[0] and row[0].startswith(b'v10') and b'4111111111111111' not in row[0] for row in cards)
    result[name] = {'addresses': addresses, 'cards': len(cards), 'cardsEncrypted': bool(cards)}
print(json.dumps(result, indent=2))

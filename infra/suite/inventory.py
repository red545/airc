#!/usr/bin/env python3
"""Record the canonical build-app scenario function without launching any apps."""
import json
import re
from pathlib import Path
import subprocess
import sys


def inventory(root):
    source = (root / 'scripts/build-app.sh').read_text()
    function = source.split('  scenarios() {', 1)[1].split('\n  FAILED=0', 1)[0]
    function = re.sub(r'^.*python3 \"\$ROOT/scripts/check-redirect-history.py\".*$', '', function, flags=re.M)
    # The canonical function uses only isolated fixture directories here.
    function = function.replace('rm -rf "$home"; ', '')
    script = '''set -eu
export AIRC_MEDIA_PROMPT_CHECKS=0 AIRC_SHIP_GATE=1
ROOT="$PWD"
APP="$ROOT/build/Airc.app"
CHROMIUM_APP="$ROOT/build/Airc-Chromium.app"
ui_open() { python3 infra/suite/inventory.py record "$@"; }
scenarios() {''' + function + '''
for engine in webkit chromium; do scenarios "$engine" "$ROOT/build/inventory/$engine"; done
'''
    subprocess.run(['bash', '-c', script], cwd=root, check=True, stdout=subprocess.DEVNULL)
    cases = [json.loads(x) for x in (root / 'build/inventory.jsonl').read_text().splitlines()]
    # Long-running instrumented workload is part of background qualification.
    for engine in ('webkit', 'chromium'):
        base = next(x for x in cases if x['engine'] == engine)
        args = list(base['command'])
        args[args.index('--script') + 1] = 'perf'
        args[args.index('--data-dir') + 1] = str(root / 'build/snapshot-home' / engine / 'Perf')
        cases.append(dict(engine=engine, script='perf', command=args))
    return cases

if __name__ == '__main__' and sys.argv[1] == 'record':
    args = sys.argv[2:]
    script = args[args.index('--script') + 1]
    engine = next(x.split('=', 1)[1] for x in args if x.startswith('--engine='))
    with Path('build/inventory.jsonl').open('a') as out:
        out.write(json.dumps(dict(engine=engine, script=script, command=['open', *args])) + '\n')
    with (Path(args[args.index('--snapshot') + 1]) / 'log.txt').open('a') as out:
        out.write('[' + script + ']\n')

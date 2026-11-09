#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""A preparation run passes only when all mandatory stages actually completed."""
from pathlib import Path
import json
import sys

REQUIRED = {'mac-online', 'export', 'ui-preflight', 'engine-framework',
            'test-AircDesign', 'test-AircImport', 'test-AircKit', 'build-app'}


def failures(path):
    seen = set()
    errors = []
    for line in path.read_text().splitlines():
        fields = line.split('\t')
        if len(fields) != 3:
            errors.append('malformed step record')
            continue
        name, code, duration = fields
        if name in seen:
            errors.append('duplicate step: ' + name)
        seen.add(name)
        if code != '0':
            errors.append('failed step: ' + name)
        if not duration.isdigit():
            errors.append('invalid duration: ' + name)
    errors += ['missing step: ' + name for name in sorted(REQUIRED - seen)]
    # The regular UI classifier retains some FAIL-ENV assertions under a PASS
    # aggregate. Migration qualification requires every assertion to be green.
    try:
        gate = json.loads(path.with_name('ui-gate.json').read_text())
        launches = gate['launches']
        if gate['state'] != 'PASS' or gate.get('errors') or gate.get('locks'):
            errors.append('UI acceptance did not pass cleanly')
        if not isinstance(launches, list) or not launches:
            errors.append('no UI acceptance launches')
        else:
            for launch in launches:
                if (launch['state'] != 'PASS' or launch['failures'] or
                        launch['errors'] or launch['locks']):
                    errors.append('UI acceptance not green: ' + launch['script'])
    except (OSError, ValueError, KeyError, TypeError):
        errors.append('missing or malformed UI acceptance evidence')
    return errors


if __name__ == '__main__':
    errors = failures(Path(sys.argv[1]))
    for error in errors:
        print(error, file=sys.stderr)
    sys.exit(bool(errors))

#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Prepare an explicitly dedicated agent console, while holding the UI lock.

Opt in with AIRC_UI_DEDICATED_SESSION=1. Never enable on a personal session.
No window titles, notification contents or user identities are logged.
"""
import os
import signal
import subprocess


def prepare():
    # Refuse to operate on another user's console (including via root/SSH).
    if os.stat('/dev/console').st_uid != os.getuid():
        raise RuntimeError('the console is not owned by the agent user')
    # Dismiss outstanding notification UI without editing Focus preferences or
    # notification data. launchd can restart the session service normally.
    rows = subprocess.check_output(['ps', '-axo', 'pid=,uid=,comm='], text=True)
    dismissed = 0
    for row in rows.splitlines():
        fields = row.strip().split(None, 2)
        if len(fields) != 3 or int(fields[1]) != os.getuid():
            continue
        if fields[2].endswith('/UserNotificationCenter'):
            pid = int(fields[0])
            current = subprocess.check_output(['ps', '-p', str(pid), '-o', 'uid=,comm='], text=True).strip()
            identity = current.split(None, 1)
            if len(identity) == 2 and int(identity[0]) == os.getuid() and identity[1] == fields[2]:
                os.kill(pid, signal.SIGTERM)
                dismissed += 1
    subprocess.run(['osascript', '-l', 'JavaScript', '-e', '''
ObjC.import('AppKit');
var apps = $.NSWorkspace.sharedWorkspace.runningApplications;
for (var i = 0; i < apps.count; i++) {
    var app = apps.objectAtIndex(i);
    if (app.activationPolicy == 0) app.hide;
}
'''], check=True, capture_output=True, timeout=15)
    print('UI preflight: agent console verified; Finder and other regular apps hidden; '
          f'notification UI dismissed ({dismissed}); foreground launch required', flush=True)

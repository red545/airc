#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Catch Mach ticks / nanoseconds mistakes on Apple silicon, against getrusage."""
import json, os, pathlib, resource, subprocess, time
binary = pathlib.Path(__file__).with_name('counters')
def sample():
    return json.loads(subprocess.check_output([str(binary), str(os.getpid())]))
a=sample(); r=resource.getrusage(resource.RUSAGE_SELF); before=r.ru_utime+r.ru_stime
end=time.monotonic()+0.5
while time.monotonic()<end: pass
b=sample(); r=resource.getrusage(resource.RUSAGE_SELF); actual=r.ru_utime+r.ru_stime-before
ledger=(b['cpu_ns']-a['cpu_ns'])/1e9
assert 0.9 < ledger/actual < 1.1, (ledger,actual)
print(json.dumps({'ledger_seconds':ledger,'getrusage_seconds':actual,'ratio':ledger/actual,
                  'timebase_numer':b['timebase_numer'],'timebase_denom':b['timebase_denom']}))

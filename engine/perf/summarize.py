#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Summarize evidence without reading profile contents; normalize legacy CPU ticks.

Legacy sampler omitted Mach conversion. Preserve its raw evidence and require an
explicit independently calibrated timebase; never silently assume arm64's ratio.
"""
import argparse, json, pathlib
p=argparse.ArgumentParser(); p.add_argument('root',type=pathlib.Path)
p.add_argument('--legacy-timebase', help='numerator/denominator from check-counters.py')
a=p.parse_args(); rows={}
for result in sorted(a.root.glob('engine-*/results.json')):
    d=json.loads(result.read_text()); run=result.parent
    if d.get('launch_only'): continue
    counters=json.loads((run/'counters.json').read_text())
    if 'timebase_numer' not in counters[0]['processes'][0]:
        if not a.legacy_timebase: raise RuntimeError('legacy timebase needed: '+run.name)
        n,den=map(int,a.legacy_timebase.split('/'))
        d['CPU_percent']*=n/den
        d['CPU_correction']='Raw counters mislabeled cpu_ns were Mach ticks; multiplied by '+a.legacy_timebase
    files=json.loads((run/'disk.json').read_text())
    d['model_named_bytes']=sum(v['bytes'] for name,v in files.items() if any(s in name.lower() for s in ('model','optimization','translate')))
    pages=json.loads((run/'pages.json').read_text())
    d['pages_without_error']=sum(r.get('error') is False for r in pages)
    d['page_failures']=[{'url':r['url'],'error':r.get('error')} for r in pages if r.get('error') is not False]
    d['total_processes']=sum(g['count'] for g in d['groups'].values())
    # Startup bytes written by surviving processes is a lower bound (excludes exits).
    d['live_process_disk_written']=sum(r['disk_written'] for r in counters[1]['processes'])
    rows[run.name]=d
(a.root/'summary.json').write_text(json.dumps(rows,indent=2)+'\n')
print('| Run | MB | Processes/renderers | CPU % | Interrupt wakeups/s | Data MB | Model-named MB | DOM responses |')
print('|---|---:|---:|---:|---:|---:|---:|---:|')
for name,d in rows.items():
    print(f"| {name} | {d['total_MB']:.1f} | {d['total_processes']}/{d['groups'].get('renderer',{}).get('count',0)} | {d['CPU_percent']:.3f} | {d['interrupt_wakeups_per_s']:.2f} | {d['data_bytes']/1e6:.2f} | {d['model_named_bytes']/1e6:.2f} | {d['pages_without_error']}/{d['pages']} |")

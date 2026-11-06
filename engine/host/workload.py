#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

"""Count workload processes and measure 100-tab lifecycle retention in a fresh host."""
import argparse, json, os, pathlib, signal, subprocess, time
p=argparse.ArgumentParser(); p.add_argument('app',type=pathlib.Path); p.add_argument('output',type=pathlib.Path); p.add_argument('workload',type=pathlib.Path); p.add_argument('--all',action='store_true'); p.add_argument('--leak',action='store_true'); p.add_argument('--process-per-site',action='store_true'); p.add_argument('--renderer-limit',type=int); a=p.parse_args()
a.output.mkdir(parents=True,exist_ok=False); run=a.output.resolve(); pid=None

def wait_file(name):
    deadline=time.monotonic()+90
    while not (run/name).exists():
        if time.monotonic()>deadline: raise RuntimeError('timeout: '+name)
        time.sleep(.2)

def sample(name):
    rows=[r.strip().split(None,2) for r in subprocess.check_output(['ps','-axo','pid=,ppid=,command='],text=True).splitlines()]
    owned={pid}
    for _ in range(10): owned|={int(r[0]) for r in rows if int(r[1]) in owned}
    rows=[r for r in rows if int(r[0]) in owned]
    (run/(name+'-processes.txt')).write_text('\n'.join(' '.join(r) for r in rows))
    cmd=['footprint','--noCategories','-j',str(run/(name+'.json'))]
    for child in sorted(owned): cmd+=['-p',str(child)]
    result=subprocess.run(cmd,capture_output=True,text=True,timeout=30,check=True)
    (run/(name+'.txt')).write_text(result.stdout+result.stderr)
    data=json.loads((run/(name+'.json')).read_text())
    if data['errors']: raise RuntimeError(str(data['errors']))
    return {'MB':data['total footprint']/1e6,'processes':len(rows),'renderers':sum('--type=renderer' in r[2] for r in rows)}
try:
    args=['open','-g','-n',str(a.app.resolve()),'--args','--user-data-dir='+str(run/'data'),'--use-mock-keychain','--airc-workload='+str(a.workload.resolve()),'--airc-ready='+str(run/'ready'),'--airc-pid='+str(run/'pid')]
    if a.process_per_site: args+=['--process-per-site']
    if a.renderer_limit: args+=['--renderer-process-limit='+str(a.renderer_limit)]
    if a.all: args+=['--airc-load-all=1']
    if a.leak: args+=['--airc-leak='+str(run/'closed')]
    subprocess.run(args,check=True); wait_file('ready'); pid=int((run/'pid').read_text()); time.sleep(60)
    results={'baseline':sample('baseline')}
    if a.leak:
        wait_file('closed'); time.sleep(60); results['after']=sample('after'); results['ratio']=results['after']['MB']/results['baseline']['MB']
    (run/'results.json').write_text(json.dumps(results,indent=2)); print(json.dumps(results),flush=True)
finally:
    if pid:
        cmd=subprocess.run(['ps','-p',str(pid),'-o','command='],capture_output=True,text=True).stdout
        if str(a.app.resolve()) in cmd: os.kill(pid,signal.SIGTERM)

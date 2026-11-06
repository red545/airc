#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

"""Sequential isolated app idle diagnostic. CPU first; optional tracing afterwards."""
import argparse, hashlib, json, os, pathlib, shutil, signal, struct, subprocess, time, urllib.request
from measure import CDP, processes, kind
p=argparse.ArgumentParser(); p.add_argument('app'); p.add_argument('out'); p.add_argument('--off',action='store_true',help='Disable the seven pass-6 groups; leave quietProfiling at the build default'); p.add_argument('--trace',action='store_true'); p.add_argument('--allocations',action='store_true'); p.add_argument('--flag',action='append',default=[]); p.add_argument('--seed-components',type=pathlib.Path); p.add_argument('--public',action='store_true'); p.add_argument('--settle',type=float,default=60); p.add_argument('--seconds',type=float,default=30); a=p.parse_args()
root=pathlib.Path(__file__).resolve().parents[2]; out=pathlib.Path(a.out).resolve(); out.mkdir(parents=True,exist_ok=False)
for name in ['counters','threads']:
    subprocess.run(['xcrun','clang','-O2',str(root/'engine/perf'/ (name+'.c')),'-o',str(out/name)],check=True)
app=pathlib.Path(a.app).resolve(); data=out/'data'; events=out/'events.jsonl'
w=json.loads((root/'infra/perf/workload.json').read_text())
if not a.public:
    for i,t in enumerate(w['tabs']): t['url']='data:text/html,<title>Idle</title><p>Static page '+str(i)+'</p>'
(out/'workload.json').write_text(json.dumps(w)); (out/'home/Library').mkdir(parents=True)
flags=['--engine=chromium','--ephemeral','--script','perf','--snapshot',str(out/'snapshots'),'--data-dir',str(data),'--user-data-dir='+str(out/'chromium'),'--use-mock-keychain','--remote-debugging-port=0','--perf-workload',str(out/'workload.json'),'--perf-events',str(events),'--perf-control',str(out/'control.json')]
if a.off: flags+=['--airc-switches='+','.join(k+'=off' for k in ['quietModels','quietHistory','quietCommerce','quietTranslateDownloads','quietTelemetry','quietVariations','quietSync'])]
seeded = {}
if a.seed_components:
    # Public components only, from an isolated benchmark root. No profile/Local State copy.
    for name in ['ActorSafetyLists','CertificateRevocation','Crowd Deny','SafetyTips','PKIMetadata',
                 'SSLErrorAssistant','FileTypePolicies','OnDeviceHeadSuggestModel','OriginTrials']:
        source = a.seed_components/name
        if source.is_dir():
            shutil.copytree(source,out/'chromium'/name)
            for file in source.rglob('*'):
                if file.is_file(): seeded[str(file.relative_to(a.seed_components))]=hashlib.sha256(file.read_bytes()).hexdigest()
    (out/'seed-components.json').write_text(json.dumps(seeded,indent=2))
flags += a.flag
known={}; pid=None
def owned():
    global pid
    rows=processes()
    if pid is None:
        pid=next((p for p,(_,cmd) in rows.items() if cmd.startswith(str(app/'Contents/MacOS/Airc')) and str(data) in cmd),None)
    if pid and pid in rows: known[pid]=rows[pid][1]
    for _ in range(4):
        for p,(parent,cmd) in rows.items():
            if parent in known or (str(app/'Contents/Frameworks') in cmd and str(out/'chromium') in cmd): known[p]=cmd
    return {p:cmd for p,cmd in known.items() if rows.get(p,(0,''))[1]==cmd}
def counters():
    rows=owned(); r=[json.loads(l) for l in subprocess.check_output([str(out/'counters'),*map(str,rows)],text=True).splitlines()]
    for v in r: v['type']=kind(rows[v['pid']])
    return r
def threads():
    rows={}
    for proc in owned():
        raw=subprocess.check_output([str(out/'threads'),str(proc)],text=True)
        for line in raw.splitlines():
            tid,u,s,name=line.split('\t',3); rows[str(proc)+':'+tid]={'ns':int(u)+int(s),'name':name,'pid':proc}
    return rows
try:
    subprocess.run(['open','-g','-n','--stdout',str(out/'app.log'),'--stderr',str(out/'app.log'),'--env','CFFIXED_USER_HOME='+str(out/'home'),str(app),'--args',*flags],check=True)
    deadline=time.monotonic()+120; timing=None
    while time.monotonic()<deadline:
        owned()
        if events.exists():
            timing=next((r for r in map(json.loads,events.read_text().splitlines()) if r['event']=='timings'),None)
            if timing: break
        time.sleep(.25)
    if not timing: raise RuntimeError('timings not ready')
    time.sleep(a.settle)
    before=counters(); tb=threads(); start=time.monotonic(); time.sleep(a.seconds); end=time.monotonic(); te=threads(); after=counters()
    old={r['pid']:r for r in before}; elapsed=end-start
    deltas=[dict(r,cpu_percent=(r['cpu_ns']-old[r['pid']]['cpu_ns'])/1e9/elapsed*100) for r in after if r['pid'] in old and r['start']==old[r['pid']]['start']]
    td=[dict(r,tid=k,cpu_percent=(r['ns']-tb[k]['ns'])/1e9/elapsed*100) for k,r in te.items() if k in tb]
    result={'flags':flags,'public':a.public,'timings':timing,'main_MB':next(r['footprint']/1e6 for r in after if r['pid']==pid),'CPU_percent':sum(r['cpu_percent'] for r in deltas),'processes':deltas,'threads':sorted(td,key=lambda r:-r['cpu_percent'])[:30],'churn':set(old)!=set(r['pid'] for r in after),'elapsed':elapsed,'thread_CPU_percent':sum(r['cpu_percent'] for r in td)}
    # Validate page outcomes after the CPU interval so CDP does not wake pages
    # during measurement. Public-page failures are visible in the evidence.
    port=int((out/'chromium/DevToolsActivePort').read_text().splitlines()[0])
    result['pages']=[]
    for target in json.load(urllib.request.urlopen(f'http://127.0.0.1:{port}/json/list')):
        if target['type']!='page': continue
        c=CDP(target['webSocketDebuggerUrl'])
        try:
            value=c.call('Runtime.evaluate',{'expression':"({title:document.title,url:location.href,state:document.readyState,error:!!document.querySelector('#main-frame-error')})",'returnByValue':True})
            result['pages'].append(value['result'].get('value',{}))
        except Exception as e:result['pages'].append({'url':target['url'],'error':str(e)})
        finally:c.close()
    (out/'results.json').write_text(json.dumps(result,indent=2)); (out/'raw.json').write_text(json.dumps([before,after,tb,te]))
    print(json.dumps({k:v for k,v in result.items() if k not in ['flags','processes','threads','timings']}),flush=True)
    if a.allocations:
        version=json.load(urllib.request.urlopen(f'http://127.0.0.1:{port}/json/version')); sampler=CDP(version['webSocketDebuggerUrl'])
        (out/'heap-samples.json').write_text(json.dumps(sampler.call('Memory.getBrowserSamplingProfile')))
        sampler.close()
        for command in [['vmmap','-summary',str(pid)], ['footprint','-p',str(pid)]]:
            report=subprocess.run(command,capture_output=True,text=True,timeout=30)
            (out/(command[0]+'.txt')).write_text(report.stdout+report.stderr)
    if a.trace or a.allocations:
        port=int((out/'chromium/DevToolsActivePort').read_text().splitlines()[0]); version=json.load(urllib.request.urlopen(f'http://127.0.0.1:{port}/json/version')); c=CDP(version['webSocketDebuggerUrl'])
        c.call('Tracing.start',{'categories':('disabled-by-default-memory-infra' if a.allocations else 'toplevel,base,sequence_manager,disabled-by-default-toplevel.flow'),'transferMode':'ReturnAsStream'})
        if a.allocations:
            dump=c.call('Tracing.requestMemoryDump',{'deterministic':True,'levelOfDetail':'detailed'})
            (out/'dump-result.json').write_text(json.dumps(dump))
        else: time.sleep(10)
        c.call('Tracing.end')
        while True:
            op,n=c.read(2); n&=127
            if n==126:n=struct.unpack('!H',c.read(2))[0]
            if n==127:n=struct.unpack('!Q',c.read(8))[0]
            obj=json.loads(c.read(n))
            if obj.get('method')=='Tracing.tracingComplete':break
        handle=obj['params']['stream']
        with (out/'trace.json').open('w') as f:
            while True:
                part=c.call('IO.read',{'handle':handle}); f.write(part['data'])
                if part.get('eof'):break
        c.call('IO.close',{'handle':handle}); c.close()
finally:
    rows=owned()
    for p in rows:
        try: os.kill(p,signal.SIGTERM)
        except ProcessLookupError:pass
    time.sleep(2)
    for p,cmd in rows.items():
        if processes().get(p,(0,''))[1]==cmd:
            try:os.kill(p,signal.SIGKILL)
            except ProcessLookupError:pass

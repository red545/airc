#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

"""Fresh-profile macOS benchmark. No owner-profile access, no global process kills.

Counters: physical footprint (not RSS), CPU relative to ONE core, interrupt and
package-idle wakeups (not all scheduler wakeups). First capture is an upper bound
on renderer readiness, NOT the first presented frame. CDP is loopback only.
"""
import argparse, base64, hashlib, json, os, pathlib, signal, socket, struct
import subprocess, time, urllib.request

class CDP:
    def __init__(self, url):
        from urllib.parse import urlparse
        u = urlparse(url)
        self.s = socket.create_connection((u.hostname, u.port), timeout=20)
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall((f'GET {u.path} HTTP/1.1\r\nHost: {u.netloc}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n').encode())
        header = b''
        while not header.endswith(b'\r\n\r\n'): header += self.s.recv(1)
        if not header.startswith(b'HTTP/1.1 101 '): raise RuntimeError(header)
        self.seq = 0
    def read(self, n):
        data = b''
        while len(data) < n:
            part = self.s.recv(n-len(data))
            if not part: raise EOFError('CDP disconnected')
            data += part
        return data
    def call(self, method, params=None):
        self.seq += 1
        data = json.dumps(dict(id=self.seq, method=method, params=params or {})).encode()
        mask = os.urandom(4)
        size = len(data)
        header = bytes([0x81, 0x80 | size]) if size < 126 else bytes([0x81, 0xfe])+struct.pack('!H', size)
        self.s.sendall(header+mask+bytes(v ^ mask[i%4] for i,v in enumerate(data)))
        while True:
            op, n = self.read(2); n &= 127
            if n == 126: n = struct.unpack('!H', self.read(2))[0]
            if n == 127: n = struct.unpack('!Q', self.read(8))[0]
            payload = self.read(n)
            if op & 15 == 8: raise EOFError('CDP closed')
            if op & 15 != 1: continue
            obj = json.loads(payload)
            if obj.get('id') == self.seq:
                if 'error' in obj: raise RuntimeError(obj['error'])
                return obj.get('result', {})
    def close(self): self.s.close()

def processes():
    return {int(p): (int(parent), cmd) for p,parent,cmd in
            (s.strip().split(None,2) for s in subprocess.check_output(['ps','-axo','pid=,ppid=,command='],text=True).splitlines())}

def kind(cmd):
    if '--type=renderer' in cmd: return 'renderer'
    if '--type=gpu-process' in cmd: return 'GPU'
    if 'network.mojom.NetworkService' in cmd: return 'network'
    if '--type=utility' in cmd: return 'utility'
    if 'crashpad_handler' in cmd: return 'crashpad'
    return 'browser'

def inventory(root):
    result = {}
    for p in root.rglob('*'):
        if p.is_file() and not p.is_symlink():
            s = p.stat(); result[str(p.relative_to(root))] = {'bytes':s.st_size,'allocated':s.st_blocks*512}
    return result

def main():
    p = argparse.ArgumentParser()
    p.add_argument('app', type=pathlib.Path); p.add_argument('output',type=pathlib.Path)
    p.add_argument('workload',type=pathlib.Path); p.add_argument('--chrome',action='store_true')
    p.add_argument('--launch-only',action='store_true'); p.add_argument('--all',action='store_true'); p.add_argument('--flag',action='append',default=[])
    p.add_argument('--settle',type=int,default=60); p.add_argument('--seconds',type=int,default=60)
    a = p.parse_args(); a.output.mkdir(parents=True,exist_ok=False); run=a.output.resolve()
    app=a.app.resolve(); data=run/'data'; data.mkdir(); roots=set(); known={}
    workload=json.loads(a.workload.read_text())
    selected=[t for t in workload['tabs'] if a.all or t['recent']]
    start=time.monotonic(); launch_wall=time.time()
    def owned():
        rows=processes(); current=set(roots)
        # Crashpad may be reparented, so also match our unique scratch path.
        current |= {pid for pid,(_,cmd) in rows.items() if '--user-data-dir='+str(data) in cmd or '--database='+str(data) in cmd}
        for _ in range(12): current |= {pid for pid,(parent,_) in rows.items() if parent in current}
        found={pid:rows[pid][1] for pid in current if pid in rows}
        known.update(found); return found
    def sample():
        rows=owned(); (run/'processes.txt').write_text('\n'.join(str(pid)+' '+cmd for pid,cmd in rows.items()))
        out=subprocess.run([str(pathlib.Path(__file__).with_name('counters'))]+[str(pid) for pid in rows],capture_output=True,text=True)
        counters=[json.loads(line) for line in out.stdout.splitlines()]
        if out.returncode or len(counters)!=len(rows): raise RuntimeError('process exited during sample; repeat run')
        for r in counters: r['type']=kind(rows[r['pid']])
        return {'at':time.monotonic(), 'processes':counters}
    def targets(port):
        return json.load(urllib.request.urlopen(f'http://127.0.0.1:{port}/json/list',timeout=5))
    try:
        common=['--user-data-dir='+str(data),'--use-mock-keychain','--remote-debugging-port=0','--no-first-run','--no-default-browser-check']+a.flag
        if a.chrome:
            for i,name in enumerate(workload['profiles']):
                urls=[t['url'] for t in selected if workload['spaces'][t['space']]['profile']==i]
                subprocess.run(['open','-g','-n','--stdout',str(run/'app.log'),'--stderr',str(run/'app.log'),str(app),'--args']+common+['--profile-directory='+name]+urls,check=True)
                if i == 0:
                    while not (data/'DevToolsActivePort').exists():
                        if time.monotonic()-start > 60: raise RuntimeError('Chrome startup timeout')
                        time.sleep(.02)
        else:
            subprocess.run(['open','-g','-n','--stdout',str(run/'app.log'),'--stderr',str(run/'app.log'),str(app),'--args']+common+[
                '--airc-workload='+str(a.workload.resolve()),'--airc-ready='+str(run/'ready'),'--airc-pid='+str(run/'pid')]+(['--airc-load-all=1'] if a.all else []),check=True)
        deadline=start+60
        while not (data/'DevToolsActivePort').exists():
            if time.monotonic()>deadline: raise RuntimeError('debug port timeout')
            time.sleep(.02)
        port=int((data/'DevToolsActivePort').read_text().splitlines()[0])
        if not a.chrome:
            while not (run/'pid').exists(): time.sleep(.02)
            roots.add(int((run/'pid').read_text()))
        capture=None
        while time.monotonic()<deadline:
            pages=[t for t in targets(port) if t['type']=='page' and not t['url'].startswith('chrome://')]
            if pages:
                c=CDP(pages[0]['webSocketDebuggerUrl'])
                try:
                    shot=c.call('Page.captureScreenshot',{'format':'png'})
                    (run/'first-renderer.png').write_bytes(base64.b64decode(shot['data']))
                    capture=time.monotonic()-start
                    break
                except (RuntimeError, socket.timeout): pass
                finally: c.close()
            time.sleep(.02)
        time.sleep(a.settle)
        outcomes=[]
        target_list=targets(port)
        (run/'targets.json').write_text(json.dumps(target_list,indent=2))
        for t in target_list:
            if t['type']!='page': continue
            c=CDP(t['webSocketDebuggerUrl'])
            try:
                value=c.call('Runtime.evaluate',{'expression':"JSON.stringify({url:location.href,title:document.title,timeOrigin:performance.timeOrigin,state:document.readyState,textLength:document.body?.innerText.length,paint:performance.getEntriesByType('paint').map(p=>({name:p.name,ms:p.startTime})),error:!!document.querySelector('#main-frame-error')})",'returnByValue':True})
                outcomes.append(json.loads(value['result']['value']))
            except Exception as e: outcomes.append({'url':t['url'],'error':str(e)})
            finally: c.close()
        (run/'pages.json').write_text(json.dumps(outcomes,indent=2))
        if a.launch_only:
            result={'launch_only':True,'first_renderer_capture_s':capture,
                'first_contentful_paint_s':min([r['timeOrigin']/1000+p['ms']/1000-launch_wall for r in outcomes if 'timeOrigin' in r for p in r.get('paint',[]) if p['name']=='first-contentful-paint'] or [None]),
                'pages':len(outcomes),'flags':a.flag,'chrome':a.chrome,
                'all_page_targets_responded':len(outcomes)==len(selected) and all(r.get('error') is False for r in outcomes)}
            (run/'results.json').write_text(json.dumps(result,indent=2)); print(json.dumps(result),flush=True)
            return
        before=sample(); time.sleep(a.seconds); after=sample()
        (run/'counters.json').write_text(json.dumps([before,after],indent=2))
        old={r['pid']:r for r in before['processes']}; elapsed=after['at']-before['at']
        delta={k:0 for k in ('cpu_ns','interrupt_wakeups','package_idle_wakeups','disk_written')}
        groups={}; churn=[]
        for r in after['processes']:
            g=groups.setdefault(r['type'],{'MB':0,'count':0}); g['MB']+=r['footprint']/1e6; g['count']+=1
            prev=old.pop(r['pid'],None)
            if prev is None or prev['start']!=r['start']: churn.append(r['pid']); continue
            for k in delta: delta[k]+=r[k]-prev[k]
        churn+=list(old)
        files=inventory(data); (run/'disk.json').write_text(json.dumps(files,indent=2))
        result={'first_renderer_capture_s':capture,'elapsed_s':elapsed,'groups':groups,
            'total_MB':sum(g['MB'] for g in groups.values()),'CPU_percent':delta['cpu_ns']/1e9/elapsed*100,
            'interrupt_wakeups_per_s':delta['interrupt_wakeups']/elapsed,'package_idle_wakeups_per_s':delta['package_idle_wakeups']/elapsed,
            'idle_disk_written':delta['disk_written'],'data_bytes':sum(f['bytes'] for f in files.values()),
            'data_allocated':sum(f['allocated'] for f in files.values()),'process_churn':churn,'pages':len(outcomes),
            'live_process_disk_written':sum(r['disk_written'] for r in after['processes']),
            'first_contentful_paint_s':min([r['timeOrigin']/1000+p['ms']/1000-launch_wall for r in outcomes if 'timeOrigin' in r for p in r.get('paint',[]) if p['name']=='first-contentful-paint'] or [None]),
            'flags':a.flag,'all':a.all,'chrome':a.chrome,
            'all_page_targets_responded':len(outcomes)==len(selected) and all(r.get('error') is False and r.get('state')=='complete' and r.get('textLength',0)>0 for r in outcomes)}
        (run/'results.json').write_text(json.dumps(result,indent=2)); print(json.dumps(result),flush=True)
    finally:
        owned()
        # Signal only processes with recorded identity and still-identical command.
        for pid,cmd in sorted(known.items(),key=lambda item: '--type=' in item[1]):
            if processes().get(pid,(None,None))[1]==cmd:
                try: os.kill(pid,signal.SIGTERM)
                except ProcessLookupError: pass
        time.sleep(2)
        remaining=[pid for pid,cmd in known.items() if processes().get(pid,(None,None))[1]==cmd]
        if remaining: raise RuntimeError('test processes remain: '+str(remaining))
if __name__=='__main__': main()

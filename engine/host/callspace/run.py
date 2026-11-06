#!/usr/bin/env python3
"""Run the app's callspace regression on loopback with fake devices only."""
import argparse, http.server, json, pathlib, subprocess, threading, time
p=argparse.ArgumentParser()
p.add_argument('app', type=pathlib.Path); p.add_argument('output', type=pathlib.Path)
p.add_argument('--owner-bundle', action='store_true', help='Use the existing perf script in the unmodified owner bundle')
a=p.parse_args(); app=a.app.resolve(); out=a.output.resolve(); out.mkdir(parents=True, exist_ok=False)
data=out/'data'; (data/'Chromium').mkdir(parents=True)
beats=[]
class Server(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_GET(self):
        self.send_response(200); self.send_header('Content-Type','text/html'); self.end_headers()
        self.wfile.write(pathlib.Path(__file__).with_name('fixture.html').read_bytes())
    def do_POST(self):
        item=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        item['received']=time.time(); beats.append(item)
        with (out/'heartbeat.jsonl').open('a') as f: f.write(json.dumps(item)+'\n')
        self.send_response(204); self.end_headers()
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Server)
threading.Thread(target=server.serve_forever,daemon=True).start()
args=['/usr/bin/open','-g','-n','-W','--stdout',str(out/'app.log'),'--stderr',str(out/'app.err'),str(app),'--args',
 '--engine=chromium','--snapshot',str(out/'snapshots'),'--script','callspace','--data-dir',str(data),
 '--use-mock-keychain',f'--user-data-dir={data}/Chromium',f'--airc-data-dir={data}',
 '--airc-test=memoryPressure,systemMediaPermission=granted','--use-fake-device-for-media-stream','--use-fake-ui-for-media-stream',
 f'--airc-test-url=http://127.0.0.1:{server.server_port}/']
try:
    if a.owner_bundle:
        args[args.index('callspace')]='perf'
        workload={'profiles':['One','Two'], 'spaces':[{'id':0,'profile':0},{'id':1,'profile':0},{'id':2,'profile':1}],
          'tabs':[{'space':0,'url':f'http://127.0.0.1:{server.server_port}/','recent':True},
                  {'space':1,'url':'data:text/html,<title>Other</title>','recent':True},
                  {'space':2,'url':'data:text/html,<title>Other</title>','recent':True}]}
        (out/'workload.json').write_text(json.dumps(workload))
        args += ['--perf-workload',str(out/'workload.json'),'--perf-events',str(out/'events.jsonl'),'--perf-control',str(out/'control.json')]
        child=subprocess.Popen(args)
        time.sleep(15)
        (out/'control.json').write_text('{"action":"measure"}')
        time.sleep(30)
        # Exact owned executable only; never quit the owner's running application.
        rows=subprocess.check_output(['/bin/ps','-axo','pid=,comm='],text=True).splitlines()
        for row in rows:
            fields=row.strip().split(None,1)
            if len(fields)==2 and fields[1]==str(app/'Contents/MacOS/Airc'):
                subprocess.run(['/bin/kill','-TERM',fields[0]],check=True)
        child.wait(timeout=10)
    else:
        subprocess.run(args,check=True,timeout=260)
finally: server.shutdown()
ids=set(b['id'] for b in beats)
gaps=[round((y['received']-x['received'])*1000,1) for x,y in zip(beats,beats[1:])]
logs=(out/'app.log').read_text()+'\n'+(out/'app.err').read_text()+'\n'+'\n'.join(f.read_text() for f in (out/'snapshots').rglob('*.txt'))
summary={'loads':len(ids),'beats':len(beats),'maxGapMs':max(gaps,default=None),
 'ok':any(b.get('peers')==['connected','connected'] and len(b.get('tracks') or [])==2 for b in beats) and len(ids)==1 and max(gaps,default=99999)<3000 and 'FAIL' not in logs and (a.owner_bundle or 'callspace return-hidden' in logs)}
(out/'summary.json').write_text(json.dumps(summary,indent=2));print(json.dumps(summary))
if not summary['ok']: raise SystemExit(1)

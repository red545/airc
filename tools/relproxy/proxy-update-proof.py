"""relproxy: Sparkle proof of the /releases/* external rewrite (from artifacts/release029/loopback/loopback-update-proof.py).
Run on buildmac under the UI lock, inside infra/release/update-proof.py. An unmodified copy of published 0.1.16 updates
itself with its own Sparkle from a loopback COPY of the live appcast: the 0.1.17 item, with its full and 0.1.16-delta
enclosures pointed at a PREVIEW deployment's /releases/... (the rewrite to Blob through Vercel's anycast edge), same
lengths and EdDSA signatures. The live feeds are never used. The preview's Deployment Protection bypass is passed as a
query parameter (read from BYPASS_FILE, never logged; the evidence keeps a redacted appcast copy).
Usage: proxy-update-proof.py BUILD TOOLS_DIR SOURCE FEED_DIR PREVIEW_URL BYPASS_FILE
"""
from pathlib import Path
import signal
import json, os, plistlib, subprocess, sys, time, sqlite3, uuid, threading, hashlib, pwd
expected=sys.argv[1]
assert expected.isdigit() and len(expected)==12
expected_source=sys.argv[3]
manual=False
feed_dir=Path(sys.argv[4]).resolve()
preview=sys.argv[5].rstrip('/')
assert preview.startswith('https://') and preview.endswith('.vercel.app') and 'aircbrowser.com' not in preview
bypass=Path(sys.argv[6]).read_text().strip()
assert len(bypass)>=16
assert (feed_dir/'fetched.json').is_file()
assert len(expected_source)==40
root=Path.home()/'arcfork/work/relproxy-update-proxy.noindex'
root.mkdir(exist_ok=False)
diagnostics=[Path.home()/'Library/Logs/DiagnosticReports',Path('/Library/Logs/DiagnosticReports')]
crashes_before={str(p) for folder in diagnostics for p in folder.glob('*')}
app=root/'installed/Airc.app'
home=root/'home'
data=home/'Airc'
(home/'Library').mkdir(parents=True)
data.mkdir()
# A fresh, synthetic schema-1 profile/Space proves that the real update retains data.
profile_id, space_id = str(uuid.uuid4()), str(uuid.uuid4())
profile = dict(id=profile_id, name='Release update proof profile', engineDirectory='Default', isDefault=True,
               archiveAfter='twelveHours', searchEngine='google', emoji='', createdAt=time.time(),
               color=dict(r=0.3,g=0.5,b=0.9,a=1))
space = dict(id=space_id, name='Release update proof space', profileID=profile_id, order=0,
             pinnedCollapsed=False, createdAt=time.time(),
             theme=dict(appearance='auto',colors=[],grain=0,intensity=0.81))
db=sqlite3.connect(data/'spaces.sqlite')
db.executescript('CREATE TABLE entities(kind TEXT NOT NULL,id TEXT NOT NULL,body TEXT NOT NULL,ts REAL NOT NULL,PRIMARY KEY(kind,id)); CREATE TABLE ops(seq INTEGER PRIMARY KEY AUTOINCREMENT,ts REAL NOT NULL,device TEXT NOT NULL,kind TEXT NOT NULL,id TEXT NOT NULL,op TEXT NOT NULL,body TEXT); CREATE TABLE meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);')
for kind,body in [('profile',profile),('space',space)]:
    db.execute('INSERT INTO entities VALUES(?,?,?,?)',(kind,body['id'],json.dumps(body),time.time()))
db.executemany('INSERT INTO meta VALUES(?,?)',[('device',str(uuid.uuid4())),('schema','1'),('window',json.dumps(dict(selectedSpaceID=space_id,sidebarHidden=False,sidebarOnRight=False,sidebarWidth=228)))])
db.commit();db.close()
fixture={'profile':{k:profile[k] for k in ['id','name','engineDirectory','isDefault']},
         'space':{k:space[k] for k in ['id','name','profileID']}}
(root/'data-before.json').write_text(json.dumps(fixture,indent=2)+'\n')
def verify_data():
    connection=sqlite3.connect('file:'+str(data/'spaces.sqlite')+'?mode=ro',uri=True)
    assert connection.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
    result={}
    for kind,expected_values in fixture.items():
        row=connection.execute('SELECT body FROM entities WHERE kind=? AND id=?',(kind,expected_values['id'])).fetchone()
        assert row,kind+' lost'
        body=json.loads(row[0]);result[kind]={k:body.get(k) for k in expected_values}
        assert result[kind]==expected_values,kind+' changed'
    connection.close();return result
subprocess.run(['ditto',str(Path.home()/'arcfork/updates-cache/public/202611150343/Airc.app'),str(app)],check=True)
info=lambda: plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert info()['CFBundleVersion']=='202611150343'
assert info()['CFBundleIdentifier']=='com.aircbrowser.Airc'
assert info()['SUFeedURL']=='https://aircbrowser.com/appcast.xml'
exe=str(app/'Contents/MacOS/Airc')
def own_pids():
    rows=subprocess.check_output(['ps','-axo','pid=,comm='],text=True).splitlines()
    return [int(f[0]) for row in rows if len(f:=row.strip().split(None,1))==2 and f[1]==exe]
assert not own_pids()
import http.server as _hs, socketserver as _ss, re as _re
feed_log=(root/'feed-requests.jsonl').open('w')
class FeedServer(_hs.SimpleHTTPRequestHandler):
    def __init__(self,*a,**k): super().__init__(*a,directory=str(feed_dir),**k)
    def log_message(self,fmt,*a):
        feed_log.write(json.dumps({'time':time.time(),'line':fmt%a,'path':self.path})+'\n');feed_log.flush()
class _TS(_ss.ThreadingMixIn,_ss.TCPServer): daemon_threads=True
feed_server=_TS(('127.0.0.1',0),FeedServer);feed_port=feed_server.server_address[1]
threading.Thread(target=feed_server.serve_forever,daemon=True).start()
fetched=json.loads((feed_dir/'fetched.json').read_text())
live=(feed_dir/'live-appcast.xml').read_text()
item=[i for i in _re.findall(r'<item>.*?</item>',live,_re.S) if '<sparkle:version>'+expected+'</sparkle:version>' in i]
assert len(item)==1,'live item'
item=item[0]
# keep the full enclosure and the delta from 0.1.16 only (the other deltas' files aren't served)
item=_re.sub(r'<enclosure[^>]*sparkle:deltaFrom="(?!202611150343")[^"]*"[^>]*/>','',item)
base='https://aircbrowser.com/releases/0.1.17/'+expected+'/'
assert item.count(base)==2,'expected 2 enclosure URLs'
for name in (fetched['delta']['file'],fetched['full']['file']):
    assert item.count(base+name)==1,name
    item=item.replace(base+name,preview+'/releases/0.1.17/'+expected+'/'+name+'?x-vercel-protection-bypass='+bypass)
head=live.split('<item>',1)[0];tail='</channel></rss>\n' if '</channel>' in live else ''
appcast=head+item+'\n</channel>\n</rss>\n'
(feed_dir/'appcast-loopback.xml').write_text(appcast);(root/'appcast-loopback-redacted.xml').write_text(appcast.replace(bypass,'BYPASS'))
feed_url='http://127.0.0.1:%d/appcast-loopback.xml'%feed_port
def launch():
    subprocess.run(['open','-g','-n','--stderr',str(root/'stderr.log'),'--env','CFFIXED_USER_HOME='+str(home),
                    '--env','AIRC_TELEMETRY_ENABLED=0','--env','CFNETWORK_DIAGNOSTICS=3',str(app),'--args',
                    '--data-dir',str(data),'--use-mock-keychain',
                    '-SUEnableAutomaticChecks','NO' if manual else 'YES','-SUAutomaticallyUpdate','NO' if manual else 'YES','-SUFeedURL',feed_url],check=True)
    for _ in range(80):
        pids=own_pids()
        if pids:return pids[0]
        time.sleep(.25)
    raise RuntimeError('scratch app did not launch')
# The frozen-source quit helper was compiled under both build locks before taking the UI lock.
source=Path(sys.argv[2]).resolve()
helper=source/'build/smoke-window'
assert helper.is_file(), 'Precompiled quit helper missing'
pid=None
predicate='processImagePath CONTAINS "/'+root.name+'/" OR processImagePath CONTAINS "/com.aircbrowser.Airc/org.sparkle-project.Sparkle/"'
stream_log=(root/'sparkle-verbose-stream.json').open('w')
stream=subprocess.Popen(['/usr/bin/log','stream','--level','debug','--style','ndjson','--predicate',predicate],stdout=stream_log,stderr=subprocess.STDOUT)
observer_stop=threading.Event()
def observe_archives():
    seen=set()
    with (root/'archive-observer.jsonl').open('w') as observed:
        while not observer_stop.is_set():
            rows=subprocess.check_output(['ps','-axo','pid=,comm='],text=True).splitlines()
            pids=[parts[0] for line in rows if len(parts:=line.strip().split(None,1))==2 and
                  (parts[1].startswith(str(root)+'/') or '/com.aircbrowser.Airc/org.sparkle-project.Sparkle/' in parts[1])]
            if pids:
                listing=subprocess.run(['/usr/sbin/lsof','-p',','.join(pids),'-Fn'],capture_output=True,text=True).stdout
                for line in listing.splitlines():
                    if not line.startswith('n') or expected not in line or not line.endswith(('.delta','.zip')):continue
                    name=line[1:]
                    if name in seen:continue
                    path=Path(name)
                    try:
                        record={'file':path.name,'bytes':path.stat().st_size,'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'time':time.time()}
                    except OSError:continue
                    seen.add(name);observed.write(json.dumps(record)+'\n');observed.flush()
            observer_stop.wait(.25)
observer=threading.Thread(target=observe_archives,daemon=True)
# release029 (lead, after 0.1.16's 59.85.249.88 timeouts): record where the updater connects. Every second: lsof -i of
# the app's and Sparkle's processes, and every non-loopback TCP socket of this user (nsurlsessiond included), plus DNS.
def dns_snapshot(tag):
    rows={'tag':tag,'time':time.time()}
    for host in ['aircbrowser.com','hpqylr02za4pig6a.public.blob.vercel-storage.com']:
        rows[host]=subprocess.run(['dscacheutil','-q','host','-a','name',host],capture_output=True,text=True).stdout
    with (root/'network-dns.jsonl').open('a') as f:f.write(json.dumps(rows)+'\n')
def observe_network():
    with (root/'network-lsof.jsonl').open('w') as out:
        while not observer_stop.is_set():
            rows=subprocess.check_output(['ps','-axo','pid=,comm='],text=True).splitlines()
            procs={parts[0]:parts[1] for line in rows if len(parts:=line.strip().split(None,1))==2 and
                  (parts[1].startswith(str(root)+'/') or '/org.sparkle-project.' in parts[1] or 'Sparkle' in parts[1])}
            mine=subprocess.run(['/usr/sbin/lsof','-nP','-a','-i','-p',','.join(procs)],capture_output=True,text=True).stdout if procs else ''
            tick=getattr(observe_network,'tick',0);observe_network.tick=tick+1
            everyone=[l for l in subprocess.run(['/usr/sbin/lsof','-nP','-iTCP'],capture_output=True,text=True).stdout.splitlines()[1:]
                      if '127.0.0.1' not in l and '[::1]' not in l and 'LISTEN' not in l] if tick%5==0 else None
            out.write(json.dumps({'time':time.time(),'processes':procs,'lsofProcesses':mine.splitlines(),'userTCP':everyone})+'\n');out.flush()
            # release029: 0.2 s for the app/Sparkle sockets (a ~2 s delta download fell between 1 s samples); all TCP every 1 s.
            observer_stop.wait(.2)
network_observer=threading.Thread(target=observe_network,daemon=True)
def interrupted(signum, frame):
    raise KeyboardInterrupt
signal.signal(signal.SIGTERM, interrupted)
preferences_snapshot=None
# release029: a loopback page sets a persistent cookie in 0.1.16; after the update 0.1.17 must send it back.
import http.server, socketserver
cookie_token=uuid.uuid4().hex
proof_started_at=time.time()
requests_seen=[]
class CookiePage(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        requests_seen.append({'path':self.path,'cookie':self.headers.get('Cookie',''),'time':time.time()})
        body=b'<!doctype html><title>release proof</title><p>release proof</p>'
        self.send_response(200);self.send_header('Content-Type','text/html')
        if self.path.startswith('/set'):
            self.send_header('Set-Cookie','release029='+cookie_token+'; Max-Age=86400; Path=/; HttpOnly; SameSite=Lax')
        self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
    def log_message(self,*a):pass
cookie_server=socketserver.TCPServer(('127.0.0.1',0),CookiePage);cookie_port=cookie_server.server_address[1]
threading.Thread(target=cookie_server.serve_forever,daemon=True).start()
def open_page(path):
    subprocess.run(['open','-g','-a',str(app),'http://127.0.0.1:%d%s'%(cookie_port,path)],check=True)
def wait_request(prefix,seconds=60):
    for _ in range(seconds*4):
        hits=[r for r in requests_seen if r['path'].startswith(prefix)]
        if hits:return hits[-1]
        time.sleep(.25)
    raise RuntimeError('page '+prefix+' never requested')
def helper_processes():
    rows=subprocess.check_output(['ps','-axo','pid=,comm='],text=True).splitlines()
    found=[]
    for row in rows:
        f=row.strip().split(None,1)
        if len(f)!=2 or not f[1].startswith(str(app)+'/') or '/Helpers/' not in f[1]:continue
        bundle=Path(f[1].split('.app/Contents/MacOS/')[0]+'.app')
        ident=plistlib.loads((bundle/'Contents/Info.plist').read_bytes())['CFBundleIdentifier'] if (bundle/'Contents/Info.plist').exists() else None
        found.append({'pid':int(f[0]),'helper':bundle.name,'bundleIdentifier':ident})
    return found
updater_error=None
try:
    subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
    pid=launch()
    observer.start();dns_snapshot('launch');network_observer.start()
    (root/'launched-pid.txt').write_text(str(pid)+'\n')
    verify_data()
    open_page('/set');set_hit=wait_request('/set');cookie_set_at=time.time()
    (root/'cookie-set.json').write_text(json.dumps({'port':cookie_port,'request':set_hit,'before':[h for h in helper_processes()]},indent=2)+'\n')
    if manual:
        # Fallback after a failed real attempt: no Sparkle. The published 0.1.17 replaces the app over the same data.
        time.sleep(15)
        subprocess.run([str(helper),'quit',str(pid),'60'],check=True)
        pid=None
        import shutil
        shutil.rmtree(app)
        subprocess.run(['ditto',str(Path.home()/'arcfork/updates-cache/public'/expected/'Airc.app'),str(app)],check=True)
        assert info()['CFBundleVersion']==expected
        print('PASS manual install of published '+expected+' over the 0.1.16 data (no Sparkle)',flush=True)
    else:
        log=data/'Updates.log'
        for _ in range(120):
            text=log.read_text() if log.exists() else ''
            if 'ready '+expected+': installs on quit' in text:break
            if 'aborted:' in text:
                dns_snapshot('aborted')
                raise RuntimeError('single updater attempt aborted; retain verbose logs')
            if not own_pids():raise RuntimeError('old application exited before update was ready')
            time.sleep(1)
        else:raise RuntimeError('public updater did not verify/download expected build in 120 seconds')
        (root/'updates-before-quit.log').write_text(text)
        assert text.count('downloading '+expected)==1,'Delta fell back; this proof requires delta use'
        verify_data()
        print('PASS Sparkle downloaded the published delta through the preview rewrite ('+str(fetched['delta']['bytes'])+' B, sha256 '+fetched['delta']['sha256'][:8]+', EdDSA verified by Sparkle)',flush=True)
        print('PASS original 0.1.16 downloaded and verified public build '+expected,flush=True)
        time.sleep(max(0,15-(time.time()-cookie_set_at)))
        subprocess.run([str(helper),'quit',str(pid),'60'],check=True)
        pid=None
        for _ in range(120):
            try:
                if info()['CFBundleVersion']==expected:break
            except (FileNotFoundError,plistlib.InvalidFileException):pass
            time.sleep(1)
        else:raise RuntimeError('Sparkle did not replace the scratch installation')
    subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
    subprocess.run(['xcrun','stapler','validate',str(app)],check=True)
    assert info()['CFBundleShortVersionString']=='0.1.17'
    assert info()['AircRevision']==expected_source
    engine_uuid=subprocess.check_output(['dwarfdump','--uuid',str(app/'Contents/Frameworks/Airc Framework.framework/Airc Framework')],text=True)
    assert '4C4C44B8-5555-3144-A105-AAAE3E8F229F' in engine_uuid
    pids=own_pids()
    pid=pids[0] if pids else launch()
    subprocess.run([str(helper),'window',str(pid),'90'],check=True)
    time.sleep(8)
    assert pid in own_pids()
    check_from=len(requests_seen)
    open_page('/check');check_hit=wait_request('/check');time.sleep(3)
    helpers=helper_processes()
    whatsnew=(data/'WhatsNewState.json').read_text() if (data/'WhatsNewState.json').exists() else None
    after={'request':check_hit,'cookieKept':('release029='+cookie_token) in check_hit['cookie'],'helpers':helpers,'whatsNewState':whatsnew,
           'updatesLog':[l for l in (data/'Updates.log').read_text().splitlines() if "what's new" in l] if (data/'Updates.log').exists() else []}
    (root/'after-update.json').write_text(json.dumps(after,indent=2)+'\n')
    assert after['cookieKept'],'cookie set in 0.1.16 was not sent by 0.1.17'
    assert helpers and all((h['bundleIdentifier'] or '').startswith('com.aircbrowser.Airc.helper') for h in helpers),'renamed helpers not running'
    assert any('Renderer' in h['helper'] for h in helpers),'no renderer helper running'
    print('PASS cookie kept, renamed helpers running: '+', '.join(sorted({h['bundleIdentifier'] for h in helpers})),flush=True)
    subprocess.run([str(helper),'quit',str(pid),'60'],check=True)
    pid=None
    retained=verify_data()
    (root/'data-after.json').write_text(json.dumps(retained,indent=2)+'\n')
    print('PASS 0.1.16 → 0.1.17 Sparkle install through the /releases rewrite (preview), target signature/staple and relaunch',flush=True)
    (root/'result.json').write_text(json.dumps({'passed':True,'from':'202611150343','to':expected,'version':'0.1.17','source':expected_source,'engineUUID':'4C4C44B8-5555-3144-A105-AAAE3E8F229F','sameData':True,'downloadAttempts':1,'mode':'sparkle-preview-rewrite','feed':'loopback copy, enclosures on preview /releases','files':fetched})+'\n')
except Exception as failure:
    (root/'result.json').write_text(json.dumps({'passed':False,'from':'202611150343','to':expected,'version':'0.1.17','source':expected_source,'downloadAttempts':1,'mode':'sparkle-preview-rewrite','error':repr(failure)})+'\n')
    raise
finally:
    cleanup=[]
    for p in own_pids():
        try:
            quit_result=subprocess.run([str(helper),'quit',str(p),'8'],capture_output=True,text=True,timeout=12)
            cleanup.append(dict(pid=p,action='quit',returncode=quit_result.returncode,stdout=quit_result.stdout,stderr=quit_result.stderr))
        except subprocess.TimeoutExpired:
            cleanup.append(dict(pid=p,action='quit',error='timeout'))
    for p in own_pids():
        cleanup.append(dict(pid=p,action='SIGTERM'))
        subprocess.run(['kill','-TERM',str(p)],check=False)
    for _ in range(8):
        if not own_pids(): break
        time.sleep(1)
    for p in own_pids():
        cleanup.append(dict(pid=p,action='SIGKILL'))
        subprocess.run(['kill','-KILL',str(p)],check=False)
    (root/'cleanup.json').write_text(json.dumps(cleanup,indent=2)+'\n')
    try:(feed_dir/'appcast-loopback.xml').unlink()
    except FileNotFoundError:pass
    subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister','-u',str(app)],check=False)
    time.sleep(1)
    stream.terminate()
    try:stream.wait(timeout=5)
    except subprocess.TimeoutExpired:stream.kill();stream.wait()
    stream_log.close()
    feed_server.shutdown();feed_log.close()
    observer_stop.set()
    if observer.is_alive():observer.join(timeout=10)
    if network_observer.is_alive():network_observer.join(timeout=10)
    # release029: Sparkle's and CFNetwork's own log of the attempt (download URL, task errors, remote endpoint), read-only.
    try:
        started=globals().get('proof_started_at') or ''
        log=subprocess.run(['/usr/bin/log','show','--style','compact','--last','20m','--predicate',
            'subsystem BEGINSWITH "org.sparkle-project" OR process CONTAINS "Sparkle" OR process == "Autoupdate" OR (subsystem == "com.apple.CFNetwork" AND (process == "Airc" OR process CONTAINS "Sparkle" OR process == "Downloader"))'],
            capture_output=True,text=True,timeout=120).stdout
        (root/'sparkle-log.txt').write_text(log.replace(bypass,'BYPASS'))
    except Exception as e:(root/'sparkle-log.txt').write_text('log show failed: '+repr(e)+'\n')
    if (data/'Updates.log').exists(): (root/'Updates.log').write_bytes((data/'Updates.log').read_bytes())
    time.sleep(5)
    crashes=[]
    for folder in diagnostics:
        for path in folder.glob('*'):
            if str(path) in crashes_before or not path.is_file():continue
            raw=path.read_text(errors='replace')
            if 'Airc' in path.name or str(root) in raw:
                name=('system-' if str(folder).startswith('/Library/') else '')+path.name
                crashes.append(name);(root/name).write_text(raw)
    (root/'crash-audit.json').write_text(json.dumps({'newReports':crashes})+'\n')
    assert not crashes, 'New crash report during public update proof'
    assert not any(c.get('action') in ('SIGTERM','SIGKILL') or c.get('error') or c.get('returncode',0)!=0 for c in cleanup), 'Public update app did not quit cleanly'

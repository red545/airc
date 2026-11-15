#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Bounded build-Mac release gate. Run inside ui-check-lock.py with its coordinator handshake.
No retry, skip, missing PID, crash, or assertion failure can become a passing gate.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import select
import shutil
import socket
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(ROOT / 'infra'))
import ui_gate

def command(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, timeout=kwargs.pop('timeout', 10), **kwargs)

def save(path, value):
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def run_case(case, engine, out, deadline, driver, sharing_base):
    script = case['script']
    evidence = out / (engine + '-' + script)
    evidence.mkdir()
    data = out / ('data-' + engine if script.startswith('release-fast') else 'data-' + engine + '-' + script)
    (data / "Chromium").mkdir(parents=True, exist_ok=True)
    home = out / ('home-' + engine)
    (home / 'Library').mkdir(parents=True, exist_ok=True)
    bundle = ROOT / 'build' / ('Airc.app' if engine == 'webkit' else 'Airc-Chromium.app')
    exe = (bundle / 'Contents/MacOS/Airc').resolve()
    variables = dict(CFFIXED_USER_HOME=str(home), NSUnbufferedIO='YES', AIRC_UI_DEDICATED_SESSION='1',
                     AIRC_REAL_KEYS='1', AIRC_REAL_CLICKS='1', AIRC_LA_AS_OWNER='1', AIRC_SHIP_GATE='1',
                     AIRC_DISABLE_LEGACY_WINDOW_CAPTURE='1', AIRC_MEDIA_PROMPT_CHECKS='0', AIRC_MEDIALIB_DEVICES='0',
                     AIRC_TELEMETRY_ENABLED='0', AIRC_SHARING_BASE=sharing_base)
    args = ['open', '-n', '-W', '--stdout', str(evidence/'stdout.txt'), '--stderr', str(evidence/'stderr.txt')]
    for k, v in variables.items(): args += ['--env', k+'='+v]
    args += [str(bundle), '--args', '--engine='+engine, '--script', script, '--snapshot', str(evidence),
             '--data-dir', str(data), '--airc-data-dir='+str(data), '--autoplay-policy=no-user-gesture-required']
    if script == 'onboarding-e2e': args += ['--onboarding', '--ephemeral']
    before = ui_gate.matching_app_pids(exe, evidence, script)
    assert not before, 'Own test executable already running'
    started = time.monotonic()
    limit = min(deadline, started + case['timeout_seconds'])
    exits = {}; events = select.kqueue()
    process = subprocess.Popen(args, close_fds=False)
    seen = set(); green_clicked = False; result = {}; error = None; handled_keys = set()
    launcher_finished = None
    def stage():
        path=evidence/'step.txt'
        return path.read_text().strip() if path.exists() else 'launch'
    def exit_description(pid):
        status=exits.get(str(pid))
        if status is None: return f'app PID {pid} disappeared without exit-status evidence at step {stage()}'
        if os.WIFEXITED(status): return f'app exited (status {os.WEXITSTATUS(status)}) at step {stage()} (PID {pid})'
        return f'app exited (signal {os.WTERMSIG(status)}) at step {stage()} (PID {pid})'
    def drain_exits(strict=True):
        for event in events.control(None,32,0):
            assert not event.flags & select.KQ_EV_ERROR, 'PID exit monitor failed'
            exits[str(event.ident)]=event.data
            if strict and event.data!=0: raise RuntimeError(exit_description(event.ident))
    def live(pid):
        drain_exits()
        if pid not in ui_gate.matching_app_pids(exe,evidence,script):
            drain_exits()
            raise RuntimeError(exit_description(pid))
        if time.monotonic()>=limit: raise TimeoutError('Case/global hard timeout')
    def window_state(pid,op='state'):
        live(pid)
        return json.loads(subprocess.check_output(['/usr/bin/osascript','-l','JavaScript',str(HERE/'fast-window-state.js'),str(pid),op],text=True,timeout=min(5,max(.1,limit-time.monotonic()))))
    def registered(pid,label):
        began=time.monotonic(); stop=min(limit,began+8); samples=[]
        while True:
            current=window_state(pid)
            samples.append(dict(seconds=round(time.monotonic()-began,3),registered=current['registered'],active=current['active']))
            save(evidence/('registration-'+label+'.json'),samples)
            if current['registered']: return current
            if time.monotonic()>=stop: raise TimeoutError('Launch Services did not register the live PID before '+label)
            time.sleep(.2)
    def drive(args,path):
        response=subprocess.run([str(driver),'--json',*args],capture_output=True,text=True,timeout=min(10,max(.1,limit-time.monotonic())))
        output=response.stdout.strip()
        save(path,dict(returncode=response.returncode,stdout=output,stderr=response.stderr))
        try: ok=json.loads(output).get('ok') is True
        except (ValueError,AttributeError): ok=False
        if response.returncode or not ok: raise RuntimeError('Driver rejected step '+stage()+': '+output)
        return output
    try:
        with (evidence/'pid-watch.jsonl').open('w') as watch:
            while True:
                now = time.monotonic()
                pids = ui_gate.matching_app_pids(exe, evidence, script)
                for pid in pids - seen:
                    # Darwin NOTE_EXITSTATUS is valid when we may signal the target,
                    # including a same-user app parented by Launch Services.
                    events.control([select.kevent(pid, filter=select.KQ_FILTER_PROC,
                                   flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                                   fflags=select.KQ_NOTE_EXIT | 0x04000000)], 0, 0)
                seen |= pids
                drain_exits()
                watch.write(json.dumps({'elapsed': round(now-started, 3), 'pids': sorted(pids), 'launcher': process.poll(),'step':stage(),'exit_statuses':dict(exits)})+'\n'); watch.flush()
                if ui_gate.screen_locked() is not False: raise RuntimeError('Screen locked during gate')
                log = (evidence/'log.txt').read_text() if (evidence/'log.txt').exists() else ''
                stdout=(evidence/'stdout.txt').read_text() if (evidence/'stdout.txt').exists() else ''
                if re.search(r'^(?:\[snapshot\] )?(FAIL(?:-ENV|-INDEPENDENT)?|ENGINE-FAIL|SKIP) ', log+'\n'+stdout, re.M):
                    raise RuntimeError('Raw assertion failure or skipped gate')
                if now >= limit: raise TimeoutError('Case/global hard timeout')
                if not seen and now-started > 15: raise RuntimeError('No PID after launch')
                launcher_status = process.poll()
                if launcher_status is not None:
                    if launcher_status != 0: raise RuntimeError('Launcher failed: '+str(launcher_status))
                    if launcher_finished is None: launcher_finished = time.monotonic()
                    # open -W can return between our PID snapshot and the kernel's
                    # exit event. Require all three independent completion proofs;
                    # give normal asynchronous termination a bounded five seconds.
                    if seen and not pids and exits == {str(pid): 0 for pid in seen}:
                        assert stage() == 'scenario-finish', 'App exited before our scenario finished'
                        assert log, 'App exited without a completion log'
                        break
                    if time.monotonic()-launcher_finished >= 5:
                        if pids: raise TimeoutError('App did not quit within five seconds after launcher returned')
                        raise RuntimeError('Launcher returned without complete app exit-status evidence')
                    time.sleep(.05)
                    continue
                key_request=evidence/'key-request.json'
                if key_request.exists():
                    key=json.loads(key_request.read_text()); request_id=key['id']
                    assert re.fullmatch('[A-Fa-f0-9-]{36}',request_id), 'Invalid key request ID'
                    if request_id not in handled_keys:
                        handled_keys.add(request_id)
                        reply=evidence/('key-response-'+request_id+'.json')
                        try:
                            assert key['pid'] in pids and key['key'] in ['cmd+opt+n','ctrl+cmd+f','cmd+w','esc']
                            assert re.fullmatch('[a-z-]+',key['step'])
                            registered(key['pid'],key['step'])
                            output=drive(['--key',key['key'],'--pid',str(key['pid'])],evidence/('key-driver-'+request_id+'.json'))
                            save(reply,dict(ok=True,output=output))
                        except Exception as failure:
                            save(reply,dict(ok=False,error=str(failure)))
                            raise
                request = evidence/'green-request'
                if request.exists() and not green_clicked:
                    pid = int(request.read_text()); assert pid in pids
                    registered(pid,'fullscreen-green-exit')
                    window_state(pid,'hover'); time.sleep(1.3)
                    current = window_state(pid); save(evidence/'green-before.json', current)
                    assert current['active'], 'Green button target lost foreground'
                    bars = [w['bounds'] for w in current['windows'] if w['layer']==0 and w['bounds']['Width']>500 and 15<=w['bounds']['Height']<=128]
                    assert len(bars)==1, 'No unique revealed native fullscreen titlebar'
                    bar=bars[0]
                    drive(['--click',str(bar['X']+62),str(bar['Y']+min(14,bar['Height']/2))],evidence/'green-driver.json')
                    green_clicked=True
                    (evidence/'green-clicked').write_text('real click accepted\n')
                time.sleep(0.15)
        assert seen, 'No PID observed'
        assert exits == {str(pid): 0 for pid in seen}, 'Missing clean process-exit evidence'
        assert process.wait(timeout=2)==0, 'Launch/quit failed'
        log=(evidence/'log.txt').read_text()
        assert '['+script+']' in log and 'PASS ' in log, 'No scenario evidence'
        assert not re.search(r'^(FAIL(?:-ENV|-INDEPENDENT)?|ENGINE-FAIL|SKIP) ',log,re.M), 'Failed or skipped assertion'
        if script=='release-fast':
            assert green_clicked, 'Real green click did not run'
            for proof in ['http loaded:', 'https loaded:', 'create and edit through editor', 'real PID-targeted', 'real key enters', 'real green-button click exits', 'local create/read snapshot matches']:
                assert any(line.startswith('PASS ') and proof in line for line in log.splitlines()), 'Missing '+proof
        if script=='redirects':
            with (evidence/'history.log').open('w') as f:
                command(['python3',ROOT/'scripts/check-redirect-history.py',data,evidence/'redirect-evidence.json'], stdout=f, timeout=15)
        result['state']='PASS'
    except Exception as e:
        error=repr(e); result.update(state='FAIL', error=error)
    finally:
        cleanup={}
        drain_exits(strict=False)
        if ui_gate.matching_app_pids(exe,evidence,script):
            result.update(state='FAIL',error=error or 'App still alive after case')
            ui_gate.stop_owned_app(exe,evidence,script,before,cleanup)
        if process.poll() is None:
            process.terminate()
            try: process.wait(timeout=2)
            except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=2)
        drain_exits(strict=False)
        events.close()
        result.update(engine=engine,script=script,pids=sorted(seen),exit_statuses=exits,
                      exit_descriptions=[exit_description(pid) for pid in seen if str(pid) in exits],
                      seconds=round(time.monotonic()-started,3),cleanup=cleanup)
        save(evidence/'result.json',result)
    print(json.dumps(result),flush=True)
    return result

def main():
    p=argparse.ArgumentParser(); p.add_argument('--out',type=Path,required=True); p.add_argument('--revision',required=True)
    a=p.parse_args(); out=a.out.resolve(); out.mkdir(parents=True,exist_ok=False)
    assert sys.platform=='darwin', 'Build Mac only'
    assert os.environ.get('AIRC_UI_DEDICATED_SESSION')=='1'
    config=json.loads((HERE/'fast-gate.json').read_text())
    driver=Path.home()/'arcfork/tools/airc-ui-driver/airc-ui-driver'
    report={'schema':1,'revision':a.revision,'state':'FAIL','cases':[],'driver_sha256':digest(driver),'config_sha256':digest(HERE/'fast-gate.json')}
    diagnostics=[Path.home()/'Library/Logs/DiagnosticReports',Path('/Library/Logs/DiagnosticReports')]
    before={str(p) for folder in diagnostics for p in folder.glob('*')}
    start=time.monotonic(); server=None
    try:
        command([driver,'--check'])
        for name in ['Airc.app','Airc-Chromium.app']:
            info=plistlib.loads((ROOT/'build'/name/'Contents/Info.plist').read_bytes())
            assert info['AircRevision']==a.revision, 'Wrong cut'
        node=Path(os.environ.get('AIRC_NODE_PATH') or shutil.which('node') or '/opt/homebrew/bin/node')
        assert node.is_file(), 'Set AIRC_NODE_PATH to an existing Node executable'
        with socket.socket() as listener:
            listener.bind(('127.0.0.1',0)); port=listener.getsockname()[1]
        sharing_base=f'http://127.0.0.1:{port}'
        server=subprocess.Popen([str(node),'scripts/sharing-dev.mjs',str(port)],cwd=ROOT/'apps/marketing',stdout=(out/'sharing-server.log').open('w'),stderr=subprocess.STDOUT)
        time.sleep(1); assert server.poll() is None, 'Sharing server did not start'
        for engine in config['engines']:
            for case in config['cases']:
                if engine not in case.get('engines',config['engines']): continue
                r=run_case(case,engine,out,start+config['maximum_seconds']-8,driver,sharing_base)
                report['cases'].append(r)
                assert r['state']=='PASS', engine+'-'+case['script']+' failed; release stopped'
        report['state']='PASS'
    except Exception as e: report['error']=repr(e)
    finally:
        if server and server.poll() is None:
            server.terminate()
            try: server.wait(timeout=3)
            except subprocess.TimeoutExpired:
                server.kill(); server.wait(timeout=2)
                report["state"]="FAIL"
                report["error"]="Local sharing server failed to stop"
        time.sleep(5)
        # Keep originals. Conservatively stop on any new Airc/helper crash in the exclusive UI window.
        reports=[]
        for folder in diagnostics:
            for path in folder.glob('*'):
                if str(path) in before or not path.is_file(): continue
                raw=path.read_text(errors='replace')
                if 'Airc' in path.name or str(ROOT/'build') in raw:
                    name=('system-' if str(folder).startswith('/Library/') else '')+path.name
                    reports.append(name)
                    (out/name).write_text(raw)
        report['crash_reports']=reports
        report['seconds']=round(time.monotonic()-start,3)
        report['driver_unchanged']=digest(driver)==report['driver_sha256']
        if reports or report['seconds']>config['maximum_seconds'] or not report['driver_unchanged']: report['state']='FAIL'
        save(out/'fast-gate-result.json',report)
        print(f"FAST GATE {report['state']}: {report['seconds']:.3f} seconds (limit 600)",flush=True)
    return 0 if report['state']=='PASS' else 1

if __name__=='__main__': sys.exit(main())

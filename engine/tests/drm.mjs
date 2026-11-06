// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// Dedicated fixture: no camera, microphone, screen capture or account access.
import fs from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import {spawn} from 'node:child_process';
import assert from 'node:assert/strict';
const [appArg, scratchArg, mode] = process.argv.slice(2);
if (!appArg || !scratchArg) throw new Error('Usage: node engine/tests/drm.mjs APP NEW_SCRATCH_DIR');
const app=path.resolve(appArg), scratch=path.resolve(scratchArg);
if(mode==='--playback-only') {
  // Explicit retry only in this harness's previous isolated test directory.
  await fs.access(path.join(scratch,'default-on.json'));
} else {
  await fs.mkdir(scratch); // never reuse an owner profile
  await fs.mkdir(path.join(scratch,'Chromium'));
}
const fixture=await fs.readFile(new URL('./drm.html',import.meta.url));
const server=http.createServer((req,res)=>{res.writeHead(200,{'Content-Type':'text/html','Cache-Control':'no-store'});res.end(fixture);});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const url=`http://127.0.0.1:${server.address().port}/`;
async function run(name, enabled) {
  const result=path.join(scratch,`${name}.json`), pidPath=path.join(scratch,`${name}.pid`);
  const args=['-g','-n','-W','--stdout',path.join(scratch,`${name}.log`),'--stderr',path.join(scratch,`${name}.log`),app,'--args',
    `--user-data-dir=${scratch}/Chromium`,`--airc-data-dir=${scratch}`,'--use-mock-keychain','--airc-background',
    // A covered background test window must still initialize its media player.
    // These test-only flags do not activate the app or invoke capture APIs.
    '--disable-backgrounding-occluded-windows','--disable-background-media-suspend',
    `--drm-url=${url}`,`--drm-result=${result}`,`--drm-pid=${pidPath}`,
    `--log-net-log=${scratch}/${name}-netlog.json`,'--net-log-capture-mode=IncludeSensitive','--enable-logging=stderr','--vmodule=request_sender=2,update_checker=2,component=2,component_installer=2,crx_downloader=2'];
  if(enabled!==undefined) args.push(`--drm-enabled=${enabled?'on':'off'}`);
  if(name==='off-restart') args.push('--drm-profile=DRM New Profile');
  await new Promise((resolve,reject)=>{
    const child=spawn('/usr/bin/open',args,{stdio:'ignore'});
    const timer=setTimeout(async()=>{
      try { const pid=Number(await fs.readFile(pidPath,'utf8')); if(pid>1) process.kill(pid,'SIGTERM'); } catch {}
      reject(new Error(`${name}: deadline`));
    },450000);
    child.on('error',e=>{clearTimeout(timer);reject(e);});
    child.on('exit',code=>{clearTimeout(timer);code===0?resolve():reject(new Error(`open exit ${code}`));});
  });
  const data=JSON.parse(await fs.readFile(result,'utf8'));
  console.log(name,JSON.stringify(data));
  return data;
}
try {
  if(mode==='--playback-only') {
    const data=await run('playback-retry',true);
    assert.equal(data.eme?.result?.value?.phase,'eme-complete');
    assert.equal(data.demo?.result?.value?.phase,'playback-complete');
    console.log('PASS encrypted playback retry');
  } else {
  // Collect all outcomes before asserting, even if the service rejects a license.
  const on=await run('default-on');
  const off=await run('off',false);
  const restart=await run('off-restart');
  const restored=await run('on-again',true);
  for(const data of [on,off,restart,restored])
    assert(data.state.registeredComponents.includes('oimompecagnajdejgnnjijobebaeigek') && data.state.registeredComponents.length > 1);
  assert.equal(on.initialState.enabled,true);
  assert.equal(restart.initialState.enabled,false);
  for(const data of [off,restart]) {
    const value=data.eme?.result?.value;
    assert.equal(value?.phase,'eme-failed');
    assert.equal(value.events.at(-1).detail.name,'NotSupportedError');
  }
  for(const data of [on,restored]) {
    assert.equal(data.eme?.result?.value?.phase,'eme-complete');
    assert.equal(data.demo?.result?.value?.phase,'playback-complete');
  }
  console.log('PASS default, restored components, EME message, public encrypted playback, persisted off and re-enable');
  }
} finally { server.close(); }

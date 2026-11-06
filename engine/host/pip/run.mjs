#!/usr/bin/env node
// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import fs from 'node:fs/promises';
import path from 'node:path';
import {spawn,execFileSync} from 'node:child_process';
import {createServer} from 'node:https';
const [app,scratch,mode='call',transition='tab',disabled='0',overlay='']=process.argv.slice(2);
if(!app||!scratch)throw Error('run.mjs <AircHost.app> <fresh scratch dir> [call|video|muted|audio] [tab|space|window] [0|1 disabled] [overlay]');
if(overlay&&(overlay!=='overlay'||mode==='call'))throw Error('overlay runs video fixtures only (no capture devices)');
if(!['call','video','muted','audio'].includes(mode)||!['tab','space','window'].includes(transition))throw Error('invalid fixture');
const dir=path.resolve(scratch);await fs.mkdir(dir);await fs.mkdir(path.join(dir,'Chromium'));
// Self-signed cert is confined to this scratch host and this loopback listener.
execFileSync('/usr/bin/openssl',['req','-x509','-newkey','rsa:2048','-nodes','-keyout',`${dir}/key.pem`,'-out',`${dir}/cert.pem`,'-days','1','-subj','/CN=localhost'],{stdio:'ignore'});
const html=await fs.readFile(new URL('fixture.html',import.meta.url));
const server=createServer({key:await fs.readFile(`${dir}/key.pem`),cert:await fs.readFile(`${dir}/cert.pem`)},(req,res)=>{if(req.url==='/beat'){let body='';req.on('data',d=>body+=d);req.on('end',async()=>{await fs.appendFile(`${dir}/heartbeat.jsonl`,body+'\n');res.writeHead(204);res.end()});return;}res.writeHead(200,{'Content-Type':'text/html'});res.end(html)});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
let timer;
try{
 const child=spawn('/usr/bin/open',['-g','-n','-W','--stdout',`${dir}/host.log`,'--stderr',`${dir}/host.err`,path.resolve(app),'--args',`--airc-data-dir=${dir}`,`--user-data-dir=${dir}/Chromium`,'--use-mock-keychain','--airc-trace=pip','--disable-backgrounding-occluded-windows','--ignore-certificate-errors','--airc-test=memoryPressure,systemMediaPermission=granted','--airc-smoke=native','--airc-native-case=pip',`--airc-pip-disabled=${disabled}`,`--airc-pip-mode=${mode}`,`--airc-pip-transition=${transition}`,`--airc-test-url=https://127.0.0.1:${server.address().port}/`,`--airc-report=${dir}/result.json`,`--airc-pid=${dir}/host.pid`,...(overlay?['--airc-pip-overlay=1']:['--use-fake-device-for-media-stream'])],{stdio:'inherit'});
 timer=setTimeout(async()=>{
   try{const pid=(await fs.readFile(`${dir}/host.pid`,'utf8')).trim();if(/^\d+$/.test(pid)&&execFileSync('/bin/ps',['-p',pid,'-o','comm='],{encoding:'utf8'}).trim()===path.resolve(app,'Contents/MacOS/AircHost'))process.kill(Number(pid),'SIGTERM')}catch{}
   child.kill();
 },35000);
 await new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',resolve)});
 const result=JSON.parse(await fs.readFile(`${dir}/result.json`,'utf8'));console.log(JSON.stringify(result,null,2));if(!result.ok)process.exitCode=1;
}finally{clearTimeout(timer);server.close();await fs.rm(`${dir}/key.pem`);await fs.rm(`${dir}/cert.pem`)}

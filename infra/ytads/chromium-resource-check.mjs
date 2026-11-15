// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// Build-Mac runtime probe: raw resource injection, NOT the native policy test.
import {readFile,writeFile} from 'node:fs/promises';
const [root,profile,mode='on']=process.argv.slice(2);
const info=JSON.parse(await readFile(profile+'/Agent-http.json','utf8'));
let id=0;
const rpc=async(name,args={})=>{
 const r=await fetch(info.url,{method:'POST',headers:{Authorization:'Bearer '+info.token,'Content-Type':'application/json','X-Airc-Profile':'YTADS','X-Airc-Client':'ytads-fixture'},body:JSON.stringify({jsonrpc:'2.0',id:++id,method:'tools/call',params:{name,arguments:args,_meta:{'io.modelcontextprotocol/protocolVersion':'2026-07-28'}}})});
 const result=await r.json();if(result.error||result.result?.isError)throw Error(JSON.stringify(result));return result.result;
};
const prior=new Set((await (await fetch('http://127.0.0.1:19221/json/list')).json()).map(t=>t.id));
await rpc('open_window',{url:'about:blank',width:1000,height:700});
const targets=await (await fetch('http://127.0.0.1:19221/json/list')).json();
const target=targets.find(t=>t.type==='page'&&t.url==='about:blank'&&!prior.has(t.id));
if(!target)throw Error('No fixture page target');
const socket=new WebSocket(target.webSocketDebuggerUrl);
await new Promise((resolve,reject)=>{socket.onopen=resolve;socket.onerror=reject});
const pending=new Map();const events=[];
socket.onmessage=e=>{const r=JSON.parse(e.data);if(r.id){const p=pending.get(r.id);pending.delete(r.id);r.error?p.reject(Error(JSON.stringify(r.error))):p.resolve(r.result)}else events.push(r)};
const call=(method,params={})=>new Promise((resolve,reject)=>{const n=++id;pending.set(n,{resolve,reject});socket.send(JSON.stringify({id:n,method,params}))});
await call('Page.enable');await call('Network.enable');
if(mode==='on'){
 await call('Page.addScriptToEvaluateOnNewDocument',{source:await readFile(root+'/engine/core/blocking-rust/src/video_ads.js','utf8')});
 await call('Network.setBlockedURLs',{urls:['*/doubleclick/ad','*/youtube/api/stats/ads']});
}
await call('Page.navigate',{url:'http://127.0.0.1:18761/'+(mode==='off'?'?off=1':'')});
let results;
for(let n=0;n<150;n++){
 const value=await call('Runtime.evaluate',{expression:"document.documentElement.dataset.fixtureDone==='yes'?window.fixtureResults:null",returnByValue:true});
 if(value.result?.value){results=value.result.value;break}
 await new Promise(r=>setTimeout(r,100));
}
const evaluate=async expression=>(await call('Runtime.evaluate',{expression,returnByValue:true,userGesture:true})).result?.value;
if(results){
 await evaluate("window.fixtureVideo=document.querySelector('video');fixtureVideo.muted=true;fixtureVideo.play().catch(()=>{});true");
 let playing=false;
 for(let n=0;n<60&&!playing;n++){playing=await evaluate('fixtureVideo.currentTime>.2&&!fixtureVideo.paused');await new Promise(r=>setTimeout(r,100))}
 results.push({name:'response media URL actually plays',pass:playing});
 await evaluate("fixtureVideo.pause();fixtureVideo.currentTime=2;fixtureVideo.textTracks[0].mode='showing';true");
 let media=false;
 for(let n=0;n<60&&!media;n++){media=await evaluate('Math.abs(fixtureVideo.currentTime-2)<.3&&(fixtureVideo.textTracks[0].cues?.length||0)>0');await new Promise(r=>setTimeout(r,100))}
 results.push({name:'real seek and caption cues',pass:media});
 console.log('MEDIA_STATE '+JSON.stringify(await evaluate("({time:fixtureVideo.currentTime,duration:fixtureVideo.duration,seeking:fixtureVideo.seeking,readyState:fixtureVideo.readyState,error:fixtureVideo.error?.code,seekable:[...Array(fixtureVideo.seekable.length)].map((_,n)=>[fixtureVideo.seekable.start(n),fixtureVideo.seekable.end(n)]),buffered:[...Array(fixtureVideo.buffered.length)].map((_,n)=>[fixtureVideo.buffered.start(n),fixtureVideo.buffered.end(n)]),tracks:[...fixtureVideo.textTracks].map(t=>({mode:t.mode,cues:t.cues?.length})),trackReady:document.querySelector('track').readyState})")));
}
await writeFile(root+'/build/chromium-fixture-'+mode+'.json',JSON.stringify({results,events},null,2));
console.log(JSON.stringify(results));
socket.close();await rpc('close_window');
if(!results||results.some(r=>!r.pass))throw Error('Chromium fixture failed');
console.log(`Chromium ${mode}: ${results.length} real DOM/fetch/XHR checks passed`);

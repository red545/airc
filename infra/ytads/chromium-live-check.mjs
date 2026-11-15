// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// Attended-style signed-out observation. Never invoked by the local CI fixture.
import {readFile,writeFile} from 'node:fs/promises';
const [profile,output,video]=process.argv.slice(2);
const ids=['aqz-KE-bpKQ','jNQXAC9IVRw','M7lc1UVf-VE','YE7VzlLtp-4','ScMzIvxBSi4'];
if(!ids.includes(video))throw Error('Fixed public video ID required');
const info=JSON.parse(await readFile(profile+'/Agent-http.json','utf8'));
let id=0;
const rpc=async(name,args={})=>{
 const r=await fetch(info.url,{method:'POST',headers:{Authorization:'Bearer '+info.token,'Content-Type':'application/json','X-Airc-Profile':'YTADS','X-Airc-Client':'ytads-live'},body:JSON.stringify({jsonrpc:'2.0',id:++id,method:'tools/call',params:{name,arguments:args,_meta:{'io.modelcontextprotocol/protocolVersion':'2026-07-28'}}})});
 const result=await r.json();if(result.error||result.result?.isError)throw Error(JSON.stringify(result));return result.result;
};
const prior=new Set((await (await fetch('http://127.0.0.1:19221/json/list')).json()).map(t=>t.id));
await rpc('open_window',{url:'about:blank',width:1280,height:800});
const targets=await (await fetch('http://127.0.0.1:19221/json/list')).json();
const target=targets.find(t=>t.type==='page'&&t.url==='about:blank'&&!prior.has(t.id));
if(!target)throw Error('No page target');
const socket=new WebSocket(target.webSocketDebuggerUrl);
await new Promise((resolve,reject)=>{socket.onopen=resolve;socket.onerror=reject});
const pending=new Map(), events=[];
socket.onmessage=e=>{const r=JSON.parse(e.data);if(r.id){const p=pending.get(r.id);pending.delete(r.id);r.error?p.reject(Error(JSON.stringify(r.error))):p.resolve(r.result)}else if(r.method.startsWith('Network.'))events.push(r)};
const call=(method,params={})=>new Promise((resolve,reject)=>{const n=++id;pending.set(n,{resolve,reject});socket.send(JSON.stringify({id:n,method,params}))});
const evaluate=async expression=>(await call('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true,userGesture:true}));
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const state=`(()=>{const v=document.querySelector('video');return {title:document.title,url:location.href,time:v?.currentTime||0,duration:Number.isFinite(v?.duration)?v.duration:null,paused:v?.paused??true,error:v?.error?.code||null,ad:!!document.querySelector('.ad-showing,.ad-interrupting'),signedIn:!!window.ytcfg?.get?.('LOGGED_IN'),consent:document.body.innerText.includes('Before you continue'),captionButton:document.querySelector('.ytp-subtitles-button')?.getAttribute('aria-pressed'),adFields:['adPlacements','playerAds','adSlots'].filter(k=>k in (window.ytInitialPlayerResponse||{})),text:document.body.innerText.slice(0,1600)}})()`;
await call('Page.enable');await call('Network.enable');
await call('Page.navigate',{url:'https://www.youtube.com/watch?v='+video});
await sleep(9000);
const consent=await evaluate(`(()=>{const b=[...document.querySelectorAll('button')].find(b=>b.textContent.replace(/\\s/g,'')==='Rejectall');if(b){b.click();return 'rejected'}return 'not found'})()`);
await sleep(4000);
const before=await evaluate(state);
await evaluate(`(()=>{const v=document.querySelector('video');if(!v)return false;v.muted=true;return v.play().then(()=>true,e=>String(e))})()`);
const samples=[];
for(let n=0;n<40;n++){samples.push((await evaluate(state)).result?.value);await sleep(500)}
const image=await call('Page.captureScreenshot',{format:'png'});await writeFile(output+'/playback.png',Buffer.from(image.data,'base64'));
const seek=await evaluate(`(()=>{const v=document.querySelector('video');if(!v||!Number.isFinite(v.duration))return null;v.currentTime=v.duration/2;return v.currentTime})()`);
await sleep(4000);const afterSeek=await evaluate(state);
const captions=await evaluate(`(()=>{const b=document.querySelector('.ytp-subtitles-button');if(!b||getComputedStyle(b).display==='none')return 'unavailable';b.click();return b.getAttribute('aria-pressed')})()`);
const pip=await evaluate(`(()=>{const v=document.querySelector('video');return v?.requestPictureInPicture().then(()=>true,e=>String(e))})()`);
await sleep(500);await evaluate(`document.pictureInPictureElement?document.exitPictureInPicture():null`);
await writeFile(output+'/observations.json',JSON.stringify({video,consent,before,samples,seek,afterSeek,captions,pip},null,2));
await writeFile(output+'/network.json',JSON.stringify(events,null,2));
socket.close();await rpc('close_window');
const playable=samples.filter(Boolean);console.log(JSON.stringify({video,adSamples:playable.filter(s=>s.ad).length,advanced:playable.at(-1)?.time>1,consent:playable.at(-1)?.consent,pip:pip.result?.value,captions:captions.result?.value}));

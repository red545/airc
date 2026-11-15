// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// Observation-only Boost for an isolated test profile in the unmodified app.
// It starts after DOM parsing; resource timing includes earlier completed loads.
(() => {
  if (window.__ytadsObserve) return;
  window.__ytadsObserve = true;
  const started=document.createElement('div');started.textContent='YTADS observation started';document.body.append(started);
  const requests = [], samples = [];
  const relevant = u => /googlevideo|doubleclick|youtubei|\/api\/stats\/ads|pagead/.test(String(u));
  const record = (kind, url, status) => { if (relevant(url) && requests.length < 500) requests.push({kind,url:String(url),status,time:performance.now()}); };
  performance.setResourceTimingBufferSize(5000);
  const fetch = window.fetch;
  window.fetch = function(...args) {
    const url = args[0]?.url || args[0]; record('fetch',url,'start');
    return Reflect.apply(fetch,this,args).then(r => {record('fetch',url,r.status);return r},e=>{record('fetch',url,'error');throw e});
  };
  const open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send, urls = new WeakMap();
  XMLHttpRequest.prototype.open = function(...args) {const r=Reflect.apply(open,this,args);urls.set(this,args[1]);return r};
  XMLHttpRequest.prototype.send = function(...args) {this.addEventListener('loadend',()=>record('xhr',urls.get(this),this.status),{once:true});return Reflect.apply(send,this,args)};
  let ticks=0, seek=null;
  const timer=setInterval(()=>{
    ticks++;
    const reject=[...document.querySelectorAll('button')].find(b=>b.textContent.trim()==='Reject all');
    if(reject)reject.click();
    const v=document.querySelector('video');
    if(v && v.paused && !v.ended) {v.muted=true;v.play().catch(()=>{});}
    samples.push({time:v?.currentTime||0,duration:Number.isFinite(v?.duration)?v.duration:null,paused:v?.paused??true,ended:v?.ended??false,error:v?.error?.code||null,ad:!!document.querySelector('.ad-showing,.ad-interrupting'),signedIn:!!window.ytcfg?.get?.('LOGGED_IN'),captionButton:document.querySelector('.ytp-subtitles-button')?.getAttribute('aria-pressed')});
    if(ticks===20 && Number.isFinite(v?.duration)){seek=v.duration/2;v.currentTime=seek;}
    if(ticks===30){
      clearInterval(timer);
      const resources=performance.getEntriesByType('resource').filter(e=>relevant(e.name)).slice(0,300).map(e=>({url:e.name,type:e.initiatorType,duration:e.duration,bytes:e.transferSize}));
      const report={title:document.title,url:location.href,samples,seek,requests,resources,consent:document.body.innerText.includes('Before you continue'),slots:[...document.querySelectorAll('ytd-ad-slot-renderer,ytd-display-ad-renderer,#masthead-ad')].map(e=>({tag:e.tagName,visible:getComputedStyle(e).display!=='none'&&e.getBoundingClientRect().height>0}))};
      const pre=document.createElement('pre');pre.id='ytads-observation';pre.style='position:fixed;top:0;left:0;z-index:999999;background:white;color:black;width:1200px;height:700px;overflow:auto;white-space:pre-wrap';pre.textContent='YTADS_BEGIN'+JSON.stringify(report)+'YTADS_END';document.body.append(pre);
    }
  },500);
})();

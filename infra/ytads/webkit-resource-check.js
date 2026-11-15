// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// Actual WebKit document-start fixture; complements the Airc integration scenario.
ObjC.import('AppKit');ObjC.import('WebKit');
function run(argv) {
  const root=argv[0], base=argv[1], mode=argv[2]||'on';
  const read=p=>ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(p,$.NSUTF8StringEncoding,null));
  const app=$.NSApplication.sharedApplication;app.setActivationPolicy(1);
  const config=$.WKWebViewConfiguration.alloc.init;
  config.websiteDataStore=$.WKWebsiteDataStore.nonPersistentDataStore;
  config.mediaTypesRequiringUserActionForPlayback=0;
  if(mode==='on')config.userContentController.addUserScript($.WKUserScript.alloc.initWithSourceInjectionTimeForMainFrameOnly(read(root+'/engine/core/blocking-rust/src/video_ads.js'),0,true));
  const store=$.WKContentRuleListStore.storeWithURL($.NSURL.fileURLWithPath(root+'/build/ytads-webkit-rules'));
  let compiled=mode!=='on',failure='';
  function spin(){ $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(.05)); }
  if(mode==='on')store.compileContentRuleListForIdentifierEncodedContentRuleListCompletionHandler('ytads-local',JSON.stringify([
    {trigger:{'url-filter':'.*/doubleclick/ad'},action:{type:'block'}},
    {trigger:{'url-filter':'.*/youtube/api/stats/ads'},action:{type:'block'}}
  ]),(rules,error)=>{if(error&&!error.isNil())failure=ObjC.unwrap(error.localizedDescription);else config.userContentController.addContentRuleList(rules);compiled=true;});
  const deadline=Date.now()+25000;
  while(!compiled&&Date.now()<deadline)spin();
  if(!compiled||failure)throw Error('rule compilation: '+failure);
  const frame=$.NSMakeRect(-6000,0,1000,700);
  const view=$.WKWebView.alloc.initWithFrameConfiguration(frame,config);
  const window=$.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(frame,1,2,false);
  window.contentView.addSubview(view);window.orderBack(null);
  view.loadRequest($.NSURLRequest.requestWithURL($.NSURL.URLWithString(base+(mode==='on'?'':'?off=1'))));
  let result=null,pending=false;
  while(Date.now()<deadline&&!result) {
    if(!pending){pending=true;view.evaluateJavaScriptCompletionHandler("document.documentElement.dataset.fixtureDone==='yes'?JSON.stringify(window.fixtureResults):null",(value,error)=>{
      if(value&&!value.isNil())result=JSON.parse(ObjC.unwrap(value));pending=false;
    });}
    spin();
  }
  if(!result){view.stopLoading;window.close;throw Error('WebKit fixture timed out');}
  function evaluate(body) {
    let answered=false, answer=null, errorMessage='';
    view.evaluateJavaScriptCompletionHandler('JSON.stringify((()=>{'+body+'})())',(value,error)=>{
      if(error&&!error.isNil())errorMessage=ObjC.unwrap(error.localizedDescription);
      else if(value&&!value.isNil())answer=JSON.parse(ObjC.unwrap(value));
      answered=true;
    });
    const end=Date.now()+3000;while(!answered&&Date.now()<end)spin();
    if(!answered||errorMessage)throw Error('media evaluation: '+errorMessage);
    return answer;
  }
  evaluate("const v=document.querySelector('video');v.muted=true;v.play().catch(()=>{});return true;");
  let playing=false,end=Date.now()+6000;
  while(!playing&&Date.now()<end){playing=evaluate("const v=document.querySelector('video');return v.currentTime>.2&&!v.paused;");spin();}
  result.push({name:'response media URL actually plays',pass:playing});
  evaluate("const v=document.querySelector('video');v.pause();v.currentTime=2;v.textTracks[0].mode='showing';return true;");
  let media=false;end=Date.now()+6000;
  while(!media&&Date.now()<end){media=evaluate("const v=document.querySelector('video');return Math.abs(v.currentTime-2)<.3&&(v.textTracks[0].cues?.length||0)>0;");spin();}
  result.push({name:'real seek and caption cues',pass:media});
  view.stopLoading;window.close;
  console.log(JSON.stringify(result));
  if(result.some(r=>!r.pass))throw Error('WebKit fixture assertions failed');
  return 'WebKit '+mode+': '+result.length+' real DOM/fetch/XHR checks passed';
}

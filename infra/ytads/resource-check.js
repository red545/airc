// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// JXA/JavaScriptCore unit probe on the build Mac, not an engine integration test.
ObjC.import('Foundation');
function run(argv) {
  const source = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null).js;
  const ctx = {};
  // A new realm avoids instrumenting JXA's own JSON serializer.
  ObjC.import('JavaScriptCore');
  const realm = $.JSContext.alloc.init;
  const setup = `
  var window = this;
  var location = {href:'https://www.youtube.com/watch?v=fixture',origin:'https://www.youtube.com'};
  var URL = class { constructor(value) {
    const m = /^(https?:\\/\\/[^/]+)([^?]*)/.exec(value);
    this.origin=m?m[1]:location.origin; this.pathname=m?m[2]:value.split('?')[0];
  }};
  var Response = class {constructor(url, value) {this.url=url;this.value=value;} json() {return {then:fn=>fn(this.value)};}};
  var XMLHttpRequest = class {};
  for (const key of ['response','responseText']) Object.defineProperty(XMLHttpRequest.prototype,key,{
    configurable:true, enumerable:true, get() {if(this.invalid)throw Error('InvalidStateError');return this.value;}
  });
  var payload = () => ({playabilityStatus:{status:'OK'},videoDetails:{videoId:'fixture'},
    streamingData:{formats:[{url:'content.webm'}]},captions:{text:'captions'},
    adPlacements:[{kind:'preroll'},{kind:'midroll'}],playerAds:[1],adSlots:[1]});
  var checks=[];
  function check(value,name) {checks.push({pass:!!value,name});}
  function clean(value,name) {
    check(!('adPlacements' in value)&&!('adSlots' in value)&&!('playerAds' in value),name+' ads');
    check(value.streamingData.formats[0].url==='content.webm'&&value.captions.text==='captions',name+' content');
  }
  `;
  realm.evaluateScript(setup);
  realm.evaluateScript(source);
  if (!realm.exception.isNil()) throw Error(ObjC.unwrap(realm.exception.toObject));
  realm.evaluateScript(`
    ytInitialPlayerResponse=payload(); clean(ytInitialPlayerResponse,'initial response');
    ytInitialPlayerResponse=payload(); clean(ytInitialPlayerResponse,'next video');
    clean(JSON.parse(JSON.stringify(payload())),'JSON parse');
    check(JSON.parse('{"adPlacements":[1]}').adPlacements.length===1,'unrelated JSON');
    let invalid=false;try{JSON.parse('bad json');}catch(_){invalid=true;}check(invalid,'parse throws');
    const resp=new Response('https://www.youtube.com/youtubei/v1/player',payload());
    clean(resp.json(),'fetch JSON');
    const xhr=new XMLHttpRequest();xhr.responseURL=resp.url;xhr.responseType='json';xhr.value=payload();
    clean(xhr.response,'XHR JSON');
    xhr.responseType='';xhr.value=JSON.stringify(payload());clean(JSON.parse(xhr.responseText),'XHR text');
    xhr.value='invalid';check(xhr.responseText==='invalid','malformed XHR retained');
    xhr.value=JSON.stringify(payload());xhr.responseURL='https://other.test/youtubei/v1/player';
    check(xhr.responseText===xhr.value,'foreign XHR untouched');
    xhr.invalid=true;invalid=false;try{xhr.responseText;}catch(_){invalid=true;}check(invalid,'native XHR error preserved');
    const outside=new Response('https://other.test/youtubei/v1/player',payload());
    check(outside.json().then(v=>v.adPlacements.length===2),'foreign fetch untouched');
  `);
  if (!realm.exception.isNil()) throw Error(ObjC.unwrap(realm.exception.toObject));
  const result=ObjC.unwrap(realm.evaluateScript('JSON.stringify(checks)').toObject);
  const checks=JSON.parse(result);
  console.log(result);
  if(checks.some(c=>!c.pass))throw Error('resource checks failed');
  return checks.length+' resource checks passed (mocked APIs, not browser integration)';
}

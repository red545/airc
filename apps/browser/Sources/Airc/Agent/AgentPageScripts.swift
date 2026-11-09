// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // agentspike: a dev-build prototype (docs/agent-ready.md); public builds compile none of Agent/
import Foundation

/// The page reads agents get, the same script on both engines (each runs it where the page's own scripts can't reach
/// it where it can: Chromium's page channel, WebKit's client world). It never returns a password, card or one-time
/// code field's value, cookies or storage: only what the page shows, plus the interactive elements with their centres
/// in page points (the screenshot's pixels), so an agent can click what it read.
enum AgentPageScripts {
    private static let library = """
    var SENS=/(^|\\s)(cc-|current-password|new-password|one-time-code)/;
    function sensitive(e){var t=(e.getAttribute('type')||'').toLowerCase();var a=(e.getAttribute('autocomplete')||'').toLowerCase();return t==='password'||SENS.test(a);}
    function shown(e){var r=e.getBoundingClientRect();if(r.width<=0||r.height<=0)return false;var s=getComputedStyle(e);return s.visibility!=='hidden'&&s.display!=='none'&&parseFloat(s.opacity||'1')>0;}
    function role(e){var r=e.getAttribute('role');if(r)return r;var t=e.tagName.toLowerCase();
      if(t==='a')return'link';if(t==='button'||t==='summary')return'button';if(t==='select')return'combobox';if(t==='textarea')return'textbox';
      if(/^h[1-6]$/.test(t))return'heading';if(t==='img')return'img';if(e.isContentEditable)return'textbox';
      if(t==='input'){var y=(e.getAttribute('type')||'text').toLowerCase();if(y==='checkbox'||y==='radio')return y;
        if(y==='button'||y==='submit'||y==='reset'||y==='image')return'button';if(y==='range')return'slider';return'textbox';}
      return t;}
    function name(e){var n=e.getAttribute('aria-label');if(n)return n;var l=e.getAttribute('aria-labelledby');
      if(l){var x=document.getElementById(l);if(x)return x.innerText;}if(e.labels&&e.labels.length)return e.labels[0].innerText;
      n=e.getAttribute('alt')||e.getAttribute('title')||e.getAttribute('placeholder');if(n)return n;
      var t=e.tagName.toLowerCase();if(t==='input'){var y=(e.getAttribute('type')||'').toLowerCase();if(y==='submit'||y==='button'||y==='reset')return e.value;return e.getAttribute('name')||'';}
      return(e.innerText||e.textContent||'').trim();}
    var SEL='a[href],button,input:not([type=hidden]),textarea,select,summary,[role],[contenteditable=""],[contenteditable=true],[tabindex]:not([tabindex="-1"]),h1,h2,h3,h4,h5,h6,img[alt]';
    function elements(limit){var out=[],all=document.querySelectorAll(SEL),n=0;
      for(var i=0;i<all.length&&out.length<limit;i++){var e=all[i];if(!shown(e))continue;n++;var r=e.getBoundingClientRect();
        var o={ref:'e'+n,role:role(e),name:String(name(e)).replace(/\\s+/g,' ').slice(0,120),x:Math.round(r.left+r.width/2),y:Math.round(r.top+r.height/2),
          w:Math.round(r.width),h:Math.round(r.height)};
        if(r.bottom<0||r.top>innerHeight||r.right<0||r.left>innerWidth)o.offscreen=true;
        var t=e.tagName.toLowerCase();
        if(t==='input'||t==='textarea'||t==='select'){if(sensitive(e))o.value=e.value?'(hidden)':'';else if(e.type==='checkbox'||e.type==='radio')o.checked=e.checked;else o.value=String(e.value).slice(0,200);}
        if(e.disabled)o.disabled=true;if(document.activeElement===e)o.focused=true;out.push(o);}
      return out;}
    function state(){return{title:document.title,url:location.href,readyState:document.readyState,visibility:document.visibilityState,
      focused:document.hasFocus(),scrollX:Math.round(scrollX),scrollY:Math.round(scrollY),viewport:[innerWidth,innerHeight],
      dpr:devicePixelRatio};}
    """

    /// `mode` "text" (what the page shows) or "outline" (its interactive elements and headings).
    static func read(mode: String, maxChars: Int) -> String {
        """
        (function(){\(library)
        var s=state();
        if(\(mode == "outline" ? "true" : "false")){s.elements=elements(400);}
        else{var t=(document.body?document.body.innerText:'')||'';s.length=t.length;s.text=t.slice(0,\(maxChars));s.truncated=t.length>\(maxChars);}
        return JSON.stringify(s);})()
        """
    }

    /// Elements whose name contains `text` (any case), or that match a CSS selector, with their roles and centres.
    static func find(text: String?, selector: String?, role: String?) -> String {
        let q = jsString(text ?? "")
        let sel = jsString(selector ?? "")
        let r = jsString(role ?? "")
        return """
        (function(){\(library)
        var q=\(q).toLowerCase(),sel=\(sel),want=\(r),out=[],all;
        if(sel){try{all=document.querySelectorAll(sel);}catch(x){return JSON.stringify({error:'bad selector'});}
          var keep=new Set(all);var list=elements(2000);var k=0;var raw=document.querySelectorAll(SEL);var idx=0;
          for(var i=0;i<raw.length;i++){var e=raw[i];if(!shown(e))continue;var o=list[idx++];if(o&&keep.has(e))out.push(o);}
          all.forEach(function(e){if(!e.matches(SEL)&&shown(e)){var b=e.getBoundingClientRect();out.push({ref:null,role:role(e),name:String(name(e)).slice(0,120),x:Math.round(b.left+b.width/2),y:Math.round(b.top+b.height/2),w:Math.round(b.width),h:Math.round(b.height)});}});}
        else{elements(2000).forEach(function(o){if((!q||o.name.toLowerCase().indexOf(q)>=0)&&(!want||o.role===want))out.push(o);});}
        var s=state();s.matches=out.slice(0,50);s.count=out.length;return JSON.stringify(s);})()
        """
    }

    static let state = "(function(){\(library)return JSON.stringify(state());})()"

    /// In an agent window's page (its own world): nothing an agent can't answer. alert, confirm and prompt return at
    /// once (an off-screen sheet would block the page and every later call), "Leave site?" is never asked, and no
    /// native drag starts (a drag session follows the person's real pointer and writes the drag pasteboard).
    static let guards = """
    (function(){if(window.__aircAgentPage)return true;window.__aircAgentPage=true;
    window.alert=function(){};window.confirm=function(){return false};window.prompt=function(){return null};
    var add=EventTarget.prototype.addEventListener;
    EventTarget.prototype.addEventListener=function(t,f,o){if(t==='beforeunload')return;return add.call(this,t,f,o);};
    try{Object.defineProperty(window,'onbeforeunload',{configurable:true,get:function(){return null},set:function(){}});}catch(e){}
    add.call(document,'dragstart',function(e){e.preventDefault();},true);
    return true;})()
    """

    static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        let text = String(decoding: data, as: UTF8.self)
        return String(text.dropFirst().dropLast())
    }
}
#endif

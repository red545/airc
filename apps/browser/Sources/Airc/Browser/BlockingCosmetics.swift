// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

@MainActor enum BlockingCosmetics {
    #if AIRC_TESTING
    static var checkMessages: [String: Int] = [:]
    #endif
    static func start(engine: BrowserEngine, center: BlockingCenter) {
        guard let scripting = engine as? EnginePageScripts else { return }
        let scripts = PageScripts.shared ?? PageScripts.start(engine: scripting, existing: scripting.existingPageScript)
        scripts.set("blocking", source: source, frames: true) { [weak center] tab, message in
            MainActor.assumeIsolated {
                #if AIRC_TESTING
                if LaunchOptions.current.isScripted { checkMessages[message.kind, default: 0] += 1 }
                #endif
                guard let center, message.json.utf8.count <= 65536,
                      let data = message.json.data(using: .utf8),
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let token = object["token"] as? String, token.utf8.count <= 128,
                      let value = object["url"] as? String, value.utf8.count <= 8192,
                      let url = URL(string: value), let scheme = url.scheme, ["https", "http"].contains(scheme),
                      let actual = URL(string: message.origin),
                      url.scheme == actual.scheme, url.host == actual.host, url.port == actual.port else { return }
                let tokens: String?
                switch message.kind {
                case "ready": tokens = nil
                case "tokens":
                    guard let classes = object["classes"] as? [String], let ids = object["ids"] as? [String],
                          classes.count + ids.count <= 4096,
                          let bytes = try? JSONSerialization.data(withJSONObject: ["classes": classes, "ids": ids]) else { return }
                    tokens = String(decoding: bytes, as: UTF8.self)
                default: return
                }
                let selectors = center.selectors(for: tab, url: value, tokens: tokens, isMainFrame: message.isMainFrame)
                let enabled = center.cosmeticsEnabled(for: tab, url: value, isMainFrame: message.isMainFrame)
                #if AIRC_TESTING
                if LaunchOptions.current.isScripted {
                    checkMessages[enabled ? "enabled" : "disabled", default: 0] += 1
                    checkMessages["selectors", default: 0] += selectors.count
                }
                #endif
                guard let response = try? JSONSerialization.data(withJSONObject: ["token": token, "selectors": selectors, "enabled": enabled]),
                      let json = String(data: response, encoding: .utf8) else { return }
                if message.isMainFrame {
                    _ = scripts.callDocument(tab, frame: message.frame, origin: message.origin, part: "blocking", kind: "apply", json: json)
                } else {
                    _ = scripts.callFrameDocument(tab, frame: message.frame, origin: message.origin, part: "blocking", kind: "apply", json: json)
                }
            }
        }
        scripts.pushNow()
    }

    // Registered at document start on every frame, including private pages.
    // A constructed stylesheet avoids relying on page permission for inline
    // <style>. insertRule accepts exactly one rule, with a fixed declaration:
    // list data cannot insert scripts, @imports or arbitrary CSS declarations.
    static let source = #"""
    function install(post) {
      if (!/^https?:$/.test(location.protocol)) return function(){};
      const token = Math.random().toString(36).slice(2) + Date.now().toString(36);
      let sheet, observing = false;
      const seen = new Set(), classes = new Set(), ids = new Set();
      const selectorParser = document.createDocumentFragment();
      let scheduled = false, pending = [], count = 0, walker = null;
      function send(kind, extra) { post(kind, JSON.stringify({token, url: location.href, ...extra})); }
      send('ready', {});
      function record(node, c, i) {
        if (node.nodeType !== 1 || count >= 4096) return;
        if (node.id && node.id.length <= 256 && !ids.has(node.id)) { ids.add(node.id); i.push(node.id); count++; }
        for (const name of node.classList) {
          if (count >= 4096) break;
          if (name.length <= 256 && !classes.has(name)) { classes.add(name); c.push(name); count++; }
        }
      }
      function flush() {
        scheduled = false;
        const c = [], i = [];
        let budget = 400;
        while (budget-- > 0 && count < 4096) {
          if (walker) {
            const node = walker.nextNode();
            if (node) { record(node, c, i); continue; }
            walker = null;
          }
          const root = pending.shift(); if (!root) break;
          record(root, c, i);
          walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
        }
        // 32 bounded tokens fit under the native 64 KiB message limit even
        // when JSON escapes each code unit. A large mutation batch must not
        // discard every selector request after marking its tokens as seen.
        for (let n = 0; n < c.length; n += 32) send('tokens', {classes: c.slice(n, n + 32), ids: []});
        for (let n = 0; n < i.length; n += 32) send('tokens', {classes: [], ids: i.slice(n, n + 32)});
        if ((pending.length || walker) && count < 4096) schedule();
      }
      function schedule() { if (!scheduled) { scheduled = true; setTimeout(flush, 16); } }
      const observer = new MutationObserver(records => {
        for (const record of records) {
          if (pending.length >= 2048 || count >= 4096) break;
          if (record.type === 'attributes') pending.push(record.target);
          else for (const node of record.addedNodes) { if (pending.length < 2048 && node.nodeType === 1) pending.push(node); }
        }
        schedule();
      });
      return function receive(kind, json) {
        if (kind !== 'apply') return;
        let value; try { value = JSON.parse(json); } catch (_) { return; }
        if (value.token !== token || !Array.isArray(value.selectors)) return;
        // Disabled profiles and site exceptions do one policy handshake only:
        // no DOM walk, mutation observer or stylesheet in the off baseline.
        if (!value.enabled) { observer.disconnect(); pending = []; walker = null; return; }
        if (!sheet) {
          try { sheet = new CSSStyleSheet(); document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet]; }
          catch (_) { return; }
        }
        if (!observing) {
          observing = true;
          observer.observe(document, {subtree:true, childList:true, attributes:true, attributeFilter:['class','id']});
          pending.push(document); schedule();
        }
        for (const selector of value.selectors) {
          if (typeof selector !== 'string' || selector.length > 8192 || seen.has(selector) || seen.size >= 16384) continue;
          try {
            // Parse as a selector before stylesheet insertion: braces, at-rules
            // or declarations must never execute before post-insert validation.
            selectorParser.querySelector(selector);
            const index = sheet.insertRule(selector + '{display:none!important}', sheet.cssRules.length);
            const rule = sheet.cssRules[index];
            if (!(rule instanceof CSSStyleRule) || rule.style.length !== 1 || rule.style.display !== 'none') {
              sheet.deleteRule(index); continue;
            }
            seen.add(selector);
          } catch (_) {}
        }
      };
    }
    """#
}

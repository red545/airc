// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // agentspike: a dev-build prototype (docs/agent-ready.md); public builds compile none of Agent/
import AppKit
import WebKit

/// WebKit (the dev engine, and DRM pages inside the Chromium build): events are AppKit events made for the agent
/// window and handed straight to the web view's responder methods. Nothing is posted (no CGEventPost, so no
/// Accessibility permission) and the window never becomes key. WebKit's own occlusion detection is off for these views
/// (`_setWindowOcclusionDetectionEnabled:`, SPI), so a page in a window off screen still renders. Scripts run in
/// WebKit's isolated client world; the page guards (AgentPageScripts.guards) in the page's.
///
/// Keys need care: WebKit re-sends a key the page leaves unhandled through `NSApp.sendEvent`, which hands it to Airc's
/// key window (the person's) and the menus (⌘W would close the person's tab). So a key is a native event only when
/// that can't happen: no modifiers, not Escape or a function key, and Airc has no key window; the window drops any
/// key that comes back to it. Otherwise the page gets the key from a script (untrusted events, and the text typed
/// through the text input path, which sends no key event at all).
final class WebKitAgentDriver: AgentPageDriver {
    let engineName = "webkit"
    private var paths = ["mouse": "native (NSEvent to WKWebView)", "scroll": "native (scroll-wheel NSEvent)",
                         "right_click": "script (no context menu)", "screenshot": "engine (takeSnapshot)"]
    private var keyCounts = ["native": 0, "script": 0]
    var inputPaths: [String: String] {
        var p = paths
        p["keys"] = "native \(keyCounts["native"]!), script \(keyCounts["script"]!)"
        return p
    }
    private var eventNumber = 1
    private var visible: Set<ObjectIdentifier> = []

    /// An AppKit function-key character (NSUpArrowFunctionKey…).
    private func fk(_ code: Int) -> String { String(Character(UnicodeScalar(UInt16(code))!)) }

    private func web(_ tab: EngineTab) -> WKWebView? { (tab as? WebKitTab)?.webView }

    func prepare(_ tab: EngineTab, in window: NSWindow, visible keep: Bool, completion: @escaping (String?) -> Void) {
        guard let v = web(tab) else { return completion("not a WebKit page") }
        if keep {
            visible.insert(ObjectIdentifier(tab))
            let sel = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
            if v.responds(to: sel) {
                typealias Set = @convention(c) (AnyObject, Selector, Bool) -> Void
                unsafeBitCast(v.method(for: sel), to: Set.self)(v, sel, false)
                paths["occlusion"] = "detection off (SPI)"
            } else {
                paths["occlusion"] = "SPI missing"
            }
        }
        window.makeFirstResponder(v)
        guardPage(v) { completion(nil) }
    }

    /// The page guards, in the page's own world (they must replace the page's alert and its listeners).
    private func guardPage(_ v: WKWebView, _ done: @escaping () -> Void) {
        v.evaluateJavaScript(AgentPageScripts.guards, in: nil, in: .page) { _ in done() }
    }

    func release(_ tab: EngineTab) { visible.remove(ObjectIdentifier(tab)) }

    func installGuards(_ tab: EngineTab, completion: @escaping () -> Void) {
        guard let v = web(tab) else { return completion() }
        guardPage(v, completion)
    }

    func capture(_ tab: EngineTab, completion: @escaping (Result<CGImage, AgentDriverError>) -> Void) {
        guard let v = web(tab) else { return completion(.failure(.failed("not a WebKit page"))) }
        var answered = false
        let once: (Result<CGImage, AgentDriverError>) -> Void = { r in
            guard !answered else { return }
            answered = true
            completion(r)
        }
        // A page that never draws (a hidden one) never answers a snapshot that waits for its next frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { once(.failure(.failed("the page didn't draw within 10 s"))) }
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = visible.contains(ObjectIdentifier(tab))
        v.takeSnapshot(with: config) { image, error in
            guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return once(.failure(.failed(error?.localizedDescription ?? "no picture")))
            }
            once(.success(cg))
        }
    }

    /// The window point for a page point (AppKit's origin is the bottom left).
    private func windowPoint(_ v: WKWebView, _ p: CGPoint) -> NSPoint {
        let inView = NSPoint(x: p.x, y: v.isFlipped ? p.y : v.bounds.height - p.y)
        return v.convert(inView, to: nil)
    }

    func mouse(_ tab: EngineTab, _ e: AgentMouse, completion: @escaping (String?) -> Void) {
        guard let v = web(tab), let w = v.window else { return completion("not a WebKit page") }
        // A new document since the last press may not have its guards yet (no dialogs, no native drags).
        if e.kind == .pressed { return guardPage(v) { self.deliver(v, w, e, completion) } }
        deliver(v, w, e, completion)
    }

    private func deliver(_ v: WKWebView, _ w: NSWindow, _ e: AgentMouse, _ completion: @escaping (String?) -> Void) {
        let type: NSEvent.EventType
        switch (e.kind, e.kind == .moved ? e.held : e.button) {
        case (.moved, .left): type = .leftMouseDragged
        case (.moved, .right): type = .rightMouseDragged
        case (.moved, .middle): type = .otherMouseDragged
        case (.moved, _): type = .mouseMoved
        case (.pressed, .middle): type = .otherMouseDown
        case (.released, .middle): type = .otherMouseUp
        case (.pressed, _): type = .leftMouseDown
        case (.released, _): type = .leftMouseUp
        }
        eventNumber += 1
        guard let event = NSEvent.mouseEvent(with: type, location: windowPoint(v, e.point), modifierFlags: e.modifiers.appKit,
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                             context: nil, eventNumber: eventNumber, clickCount: e.clickCount,
                                             pressure: e.kind == .pressed ? 1 : 0) else { return completion("no event") }
        switch type {
        case .leftMouseDown: v.mouseDown(with: event)
        case .leftMouseUp: v.mouseUp(with: event)
        case .otherMouseDown: v.otherMouseDown(with: event)
        case .otherMouseUp: v.otherMouseUp(with: event)
        case .leftMouseDragged: v.mouseDragged(with: event)
        case .rightMouseDragged: v.rightMouseDragged(with: event)
        case .otherMouseDragged: v.otherMouseDragged(with: event)
        default: v.mouseMoved(with: event)
        }
        barrier(v, completion)
    }

    /// WebKit hands events to the web process without waiting; a script after them answers once they were handled
    /// (the same channel, in order).
    private func barrier(_ v: WKWebView, _ completion: @escaping (String?) -> Void) {
        v.evaluateJavaScript("1", in: nil, in: .defaultClient) { _ in completion(nil) }
    }

    private func characters(_ k: AgentKey) -> String {
        switch k.key {
        case "Enter": return "\r"
        case "Tab": return "\t"
        case "Escape": return "\u{1b}"
        case "Backspace": return "\u{7f}"
        case "Delete": return fk(NSDeleteFunctionKey)
        case "ArrowUp": return fk(NSUpArrowFunctionKey)
        case "ArrowDown": return fk(NSDownArrowFunctionKey)
        case "ArrowLeft": return fk(NSLeftArrowFunctionKey)
        case "ArrowRight": return fk(NSRightArrowFunctionKey)
        case "Home": return fk(NSHomeFunctionKey)
        case "End": return fk(NSEndFunctionKey)
        case "PageUp": return fk(NSPageUpFunctionKey)
        case "PageDown": return fk(NSPageDownFunctionKey)
        default:
            if (112...123).contains(k.windowsCode), k.key.hasPrefix("F") { return fk(NSF1FunctionKey + k.windowsCode - 112) }
            return k.text ?? k.key
        }
    }

    /// Whether a native key event is safe now (see the type's comment).
    private func nativeKeyAllowed(_ k: AgentKey, _ modifiers: AgentModifiers) -> Bool {
        modifiers.isEmpty && k.key != "Escape" && !(112...123).contains(k.windowsCode) && NSApp.keyWindow == nil
    }

    func key(_ tab: EngineTab, _ k: AgentKey, down: Bool, modifiers: AgentModifiers, completion: @escaping (String?) -> Void) {
        guard let v = web(tab), let w = v.window else { return completion("not a WebKit page") }
        guard nativeKeyAllowed(k, modifiers) else {
            if down { keyCounts["script"]! += 1 }
            return scriptKey(v, k, down: down, modifiers: modifiers, completion: completion)
        }
        if down { keyCounts["native"]! += 1 }
        let chars = characters(k)
        let responder = w.firstResponder as? NSView
        if responder == nil || !(responder!.isDescendant(of: v)) { w.makeFirstResponder(v) }
        guard let event = NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                           context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: k.macCode) else { return completion("no event") }
        if down { v.keyDown(with: event) } else { v.keyUp(with: event) }
        barrier(v, completion)
    }

    /// The key from a script: keydown/keyup on the focused element; unless the page prevents it, a typed character goes
    /// in through the text input path, Return submits the field's form, Backspace and Delete delete.
    private func scriptKey(_ v: WKWebView, _ k: AgentKey, down: Bool, modifiers: AgentModifiers,
                           completion: @escaping (String?) -> Void) {
        let js = """
        (function(type,key,code,alt,ctrl,meta,shift){var t=document.activeElement||document.body;
        var e=new KeyboardEvent(type,{key:key,code:code,altKey:alt,ctrlKey:ctrl,metaKey:meta,shiftKey:shift,bubbles:true,cancelable:true,composed:true});
        var go=t.dispatchEvent(e);if(type!=='keydown'||!go||ctrl||meta)return JSON.stringify({go:false});
        if(key==='Enter'&&t.form&&t.tagName==='INPUT'){t.form.requestSubmit();return JSON.stringify({go:false});}
        if(key==='Backspace'){document.execCommand('delete');return JSON.stringify({go:false});}
        if(key==='Delete'){document.execCommand('forwardDelete');return JSON.stringify({go:false});}
        return JSON.stringify({go:key.length===1});})(\(AgentPageScripts.jsString(down ? "keydown" : "keyup")),\(AgentPageScripts.jsString(k.key)),\(AgentPageScripts.jsString(k.code)),\(modifiers.contains(.alt)),\(modifiers.contains(.ctrl)),\(modifiers.contains(.meta)),\(modifiers.contains(.shift)))
        """
        v.evaluateJavaScript(js, in: nil, in: .page) { [weak v] result in
            let go = agentJSON(try? result.get())?["go"] as? Bool ?? false
            if go, let text = k.text, let v { v.insertText(text) }
            completion(nil)
        }
    }

    func insertText(_ tab: EngineTab, _ text: String, completion: @escaping (String?) -> Void) {
        guard let v = web(tab) else { return completion("not a WebKit page") }
        v.insertText(text)
        barrier(v, completion)
    }

    func scroll(_ tab: EngineTab, at p: CGPoint, dx: CGFloat, dy: CGFloat, modifiers: AgentModifiers,
                completion: @escaping (String?) -> Void) {
        guard let v = web(tab), let w = v.window else { return completion("not a WebKit page") }
        // A scroll-wheel CGEvent (made, never posted) for the window; AppKit wheel deltas point the other way.
        let screen = w.convertPoint(toScreen: windowPoint(v, p))
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                               wheel1: Int32(-dy), wheel2: Int32(-dx), wheel3: 0) else {
            paths["scroll"] = "script (no wheel event)"
            return scriptScroll(tab, at: p, dx: dx, dy: dy, completion: completion)
        }
        cg.location = CGPoint(x: screen.x, y: primaryHeight - screen.y)
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(w.windowNumber))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(w.windowNumber))
        cg.flags = CGEventFlags(rawValue: UInt64(modifiers.appKit.rawValue))
        // Without its window the event's location would be in screen coordinates: then a script scrolls instead.
        guard let event = NSEvent(cgEvent: cg), event.window === w else {
            paths["scroll"] = "script (the wheel event had no window)"
            return scriptScroll(tab, at: p, dx: dx, dy: dy, completion: completion)
        }
        v.scrollWheel(with: event)
        barrier(v, completion)
    }

    func evaluate(_ tab: EngineTab, _ script: String, completion: @escaping (Any?) -> Void) {
        guard let v = web(tab) else { return completion(nil) }
        v.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
            switch result { case .success(let value): completion(value); case .failure: completion(nil) }
        }
    }

    func editCommand(_ tab: EngineTab, _ command: String, completion: @escaping (String?) -> Void) {
        // The document's own editing command on the focused field: no Edit menu, no pasteboard.
        evaluate(tab, "JSON.stringify(document.execCommand(\(AgentPageScripts.jsString(command))))") { value in
            completion((value as? String) == "true" ? nil : "\(command) did nothing")
        }
    }

    func dropUnloadQuestion(_ tab: EngineTab, completion: @escaping () -> Void) {
        guard let v = web(tab) else { return completion() }
        v.evaluateJavaScript("window.onbeforeunload = null; true", in: nil, in: .page) { _ in completion() }
    }
}
#endif

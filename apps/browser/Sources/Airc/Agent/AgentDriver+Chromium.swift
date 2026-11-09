// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING && canImport(AircCore) // agentspike: dev builds with the Chromium engine
import AppKit
import AircCore

/// Chromium: everything through the tab's in-process DevTools client (`-[AircTab devToolsCall:…]`, trusted, no local
/// files), so input goes to the page's renderer, never through AppKit's key window or the window server:
/// - `Input.dispatchMouseEvent` / `dispatchKeyEvent` / `insertText`: trusted events (`isTrusted`), and the engine marks
///   DevTools key events skip-if-unhandled, so no key ever reaches Airc's menus or shortcuts;
/// - `Page.captureScreenshot`: the engine's compositor frame, also for a page nothing shows;
/// - `Emulation.setFocusEmulationEnabled`: the page counts as focused and *visible* (it holds a visible capturer), so
///   it keeps animating and painting with its window off screen. That lasts as long as the DevTools session, which
///   today's client ends when idle: an endless promise keeps it attached and is renewed after each navigation.
///   (An engine-side agent session would replace this: artifacts/agentspike/engine-agent-session.patch.)
final class ChromiumAgentDriver: AgentPageDriver {
    let engineName = "chromium"
    let inputPaths = ["mouse": "native (DevTools Input)", "keys": "native (DevTools Input)",
                      "text": "native (DevTools Input)", "scroll": "native (DevTools Input)",
                      "right_click": "script (no context menu)", "screenshot": "engine (Page.captureScreenshot)"]
    private var kept: Set<ObjectIdentifier> = []

    private func core(_ tab: EngineTab) -> AircTab? { (tab as? ChromiumTab)?.core }

    func call(_ tab: EngineTab, _ method: String, _ params: [String: Any]?, timeout: TimeInterval = 10,
              completion: @escaping ([String: Any]?, String?) -> Void) {
        guard let core = core(tab), !tab.isClosed else { return completion(nil, "the tab is closed") }
        core.devToolsCall(method, params: params, timeout: timeout) { result, error in
            completion(result as? [String: Any], error)
        }
    }

    func prepare(_ tab: EngineTab, in window: NSWindow, visible: Bool, completion: @escaping (String?) -> Void) {
        guard visible else {
            // The engine's own hidden-window behaviour (checks compare it): the guards for this document only.
            return call(tab, "Runtime.evaluate", ["expression": AgentPageScripts.guards]) { _, error in completion(error) }
        }
        kept.insert(ObjectIdentifier(tab))
        keepAttached(tab)
        arm(tab, completion)
    }

    /// What lives in the DevTools session (and goes with it): focus emulation (visible, focused), no native drags,
    /// the page guards in every new document and in this one.
    private func arm(_ tab: EngineTab, _ completion: @escaping (String?) -> Void) {
        call(tab, "Emulation.setFocusEmulationEnabled", ["enabled": true]) { [weak self] _, error in
            guard let self else { return completion(error) }
            self.call(tab, "Input.setInterceptDrags", ["enabled": true]) { _, _ in
                self.call(tab, "Page.addScriptToEvaluateOnNewDocument", ["source": AgentPageScripts.guards]) { _, _ in
                    self.call(tab, "Runtime.evaluate", ["expression": AgentPageScripts.guards]) { _, _ in completion(error) }
                }
            }
        }
    }

    /// The endless promise: answered only when the page's context goes (a navigation) or the tab closes. Each answer
    /// ends the session (and what lives in it), so it's renewed and re-armed right away; a fast failure waits a little
    /// first, and a gone tab stops it.
    private func keepAttached(_ tab: EngineTab) {
        guard kept.contains(ObjectIdentifier(tab)), !tab.isClosed else { return }
        let started = CFAbsoluteTimeGetCurrent()
        call(tab, "Runtime.evaluate", ["expression": "new Promise(function(){})", "awaitPromise": true], timeout: 0) { [weak self, weak tab] _, error in
            guard let self, let tab, !tab.isClosed, self.kept.contains(ObjectIdentifier(tab)) else { return }
            if let error, error.contains("gone") || error.contains("can't attach") || error.contains("closed") {
                self.kept.remove(ObjectIdentifier(tab)); return
            }
            let fast = CFAbsoluteTimeGetCurrent() - started < 0.5
            DispatchQueue.main.asyncAfter(deadline: .now() + (fast ? 0.25 : 0)) {
                self.keepAttached(tab)
                self.arm(tab) { _ in }
            }
        }
    }

    func release(_ tab: EngineTab) { kept.remove(ObjectIdentifier(tab)) }

    func capture(_ tab: EngineTab, completion: @escaping (Result<CGImage, AgentDriverError>) -> Void) {
        call(tab, "Page.captureScreenshot", ["format": "png", "fromSurface": true, "optimizeForSpeed": true], timeout: 10) { r, error in
            guard let b64 = r?["data"] as? String, let data = Data(base64Encoded: b64),
                  let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                return completion(.failure(.failed(error ?? "no picture")))
            }
            completion(.success(image))
        }
    }

    func installGuards(_ tab: EngineTab, completion: @escaping () -> Void) {
        call(tab, "Runtime.evaluate", ["expression": AgentPageScripts.guards], timeout: 5) { _, _ in completion() }
    }

    func mouse(_ tab: EngineTab, _ e: AgentMouse, completion: @escaping (String?) -> Void) {
        if e.kind == .pressed {
            return installGuards(tab) { [weak self] in
                guard let self else { return completion("the driver is gone") }
                self.dispatchMouse(tab, e, completion)
            }
        }
        dispatchMouse(tab, e, completion)
    }

    private func dispatchMouse(_ tab: EngineTab, _ e: AgentMouse, _ completion: @escaping (String?) -> Void) {
        let type: String
        switch e.kind { case .moved: type = "mouseMoved"; case .pressed: type = "mousePressed"; case .released: type = "mouseReleased" }
        let button = e.kind == .moved ? e.held : e.button
        var buttons = 0
        let heldNow = e.kind == .pressed ? e.button : (e.kind == .moved ? e.held : .none)
        switch heldNow { case .left: buttons = 1; case .right: buttons = 2; case .middle: buttons = 4; case .none: buttons = 0 }
        var p: [String: Any] = ["type": type, "x": e.point.x, "y": e.point.y, "modifiers": e.modifiers.rawValue,
                                "button": button.rawValue, "buttons": buttons]
        if e.kind != .moved { p["clickCount"] = e.clickCount }
        call(tab, "Input.dispatchMouseEvent", p) { _, error in completion(error) }
    }

    func key(_ tab: EngineTab, _ k: AgentKey, down: Bool, modifiers: AgentModifiers, completion: @escaping (String?) -> Void) {
        var p: [String: Any] = ["key": k.key, "code": k.code, "windowsVirtualKeyCode": k.windowsCode,
                                "nativeVirtualKeyCode": Int(k.macCode), "modifiers": modifiers.rawValue]
        if down {
            // Text only without ⌘/⌃ (a shortcut types nothing); keyDown with text is a typed character.
            if let t = k.text, modifiers.intersection([.meta, .ctrl]).isEmpty {
                p["type"] = "keyDown"; p["text"] = t; p["unmodifiedText"] = t
            } else {
                p["type"] = "rawKeyDown"
            }
        } else {
            p["type"] = "keyUp"
        }
        call(tab, "Input.dispatchKeyEvent", p) { _, error in completion(error) }
    }

    func insertText(_ tab: EngineTab, _ text: String, completion: @escaping (String?) -> Void) {
        call(tab, "Input.insertText", ["text": text]) { _, error in completion(error) }
    }

    func scroll(_ tab: EngineTab, at p: CGPoint, dx: CGFloat, dy: CGFloat, modifiers: AgentModifiers,
                completion: @escaping (String?) -> Void) {
        call(tab, "Input.dispatchMouseEvent", ["type": "mouseWheel", "x": p.x, "y": p.y, "deltaX": dx, "deltaY": dy,
                                               "modifiers": modifiers.rawValue]) { _, error in completion(error) }
    }

    func evaluate(_ tab: EngineTab, _ script: String, completion: @escaping (Any?) -> Void) {
        // The engine's page channel (as every other Airc page script); the value comes back as JSON.
        tab.evaluate(script) { completion($0) }
    }

    func editCommand(_ tab: EngineTab, _ command: String, completion: @escaping (String?) -> Void) {
        // Mac editing commands ride on a key event (Chromium on macOS takes them from the key's `commands`).
        let k = AgentKey.named(command == "selectAll" ? "a" : "z")!
        var mods: AgentModifiers = .meta
        if command == "redo" { mods.insert(.shift) }
        var p: [String: Any] = ["type": "rawKeyDown", "key": k.key, "code": k.code, "windowsVirtualKeyCode": k.windowsCode,
                                "modifiers": mods.rawValue, "commands": [command]]
        call(tab, "Input.dispatchKeyEvent", p) { [weak self] _, error in
            p["type"] = "keyUp"; p["commands"] = nil
            self?.call(tab, "Input.dispatchKeyEvent", p) { _, _ in completion(error) }
        }
    }

    func dropUnloadQuestion(_ tab: EngineTab, completion: @escaping () -> Void) {
        call(tab, "Runtime.evaluate", ["expression": "window.onbeforeunload = null; true"], timeout: 2) { _, _ in completion() }
    }

    /// The engine window an agent window wraps: internal, so no extension or history sees it, a page's
    /// window.focus() never brings it forward, and links from other apps never open in it.
    static func markInternal(_ window: EngineWindow) { (window as? ChromiumWindow)?.core.internal = true }
}
#endif

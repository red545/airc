// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit
import CoreServices

/// K07: Arc's script commands on Airc's windows, spaces and tabs (Airc.sdef; ScriptingModel.swift). A command that
/// waits for the engine (`execute`, making a private window) suspends its Apple event until the answer comes, as
/// Chrome's do; one sent from inside Airc itself (an in-process script, the K07 check) waits in place instead.
enum ScriptingActions {
    /// Shows a tab in its window, on its space: a Favorite in a space of its profile, a pinned tab in its space.
    static func show(_ tab: ScriptTab) {
        if case .privatePage(let id) = tab.ref { tab.window.privateController?.select(id); return }
        guard let c = tab.window.controller else { return }
        let store = c.store
        switch tab.ref {
        case .item(let id):
            guard let item = store.item(id) else { return }
            var spaceID = item.spaceID ?? c.currentSpaceID
            if let profile = item.profileID, store.profile(ofSpace: c.currentSpaceID).id != profile {
                spaceID = c.windowSpaces.first { $0.profileID == profile }?.id ?? spaceID
            }
            if spaceID != c.currentSpaceID { c.switchToSpace(spaceID, animated: false) }
            guard let t = try? store.openItem(id, inSpace: spaceID) else { return }
            c.show(t.id)
        case .today(let id):
            guard let t = store.tab(id) else { return }
            if let s = t.spaceID, s != c.currentSpaceID { c.switchToSpace(s, animated: false) }
            c.show(id)
        case .privatePage:
            break
        }
    }

    /// Sets a script error on `command` and returns nil, for `return fail(...)`.
    @discardableResult
    static func fail(_ command: NSScriptCommand, _ number: Int, _ message: String) -> Any? {
        command.scriptErrorNumber = number
        command.scriptErrorString = message
        return nil
    }

    /// errAEEventNotPermitted: Apple's code for a command the app refuses.
    static let notPermitted = -10004
    static let notLoaded = -1728

    /// Whether the Apple event being handled came from Airc itself (an in-process script): it can't be suspended,
    /// since its sender is waiting on this thread.
    static var isInProcess: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return true }
        if let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value, pid == getpid() { return true }
        guard let address = event.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr)) else { return false }
        switch address.descriptorType {
        case DescType(typeKernelProcessID): return address.int32Value == getpid()
        case DescType(typeProcessSerialNumber):
            // {0, kCurrentProcess}: "the current application".
            let psn = address.data.withUnsafeBytes { $0.load(as: ProcessSerialNumber.self) }
            return psn.highLongOfPSN == 0 && psn.lowLongOfPSN == UInt32(kCurrentProcess)
        default: return false
        }
    }

    /// Runs `work`, which answers once: suspends the Apple event until then (an outside script), or waits in place
    /// (an in-process one), at most `timeout` seconds. On time-out the command fails with `late`.
    static func answer(_ command: NSScriptCommand, timeout: TimeInterval, late: String,
                       _ work: (@escaping (Any?) -> Void) -> Void) -> Any? {
        var result: Any?, done = false
        if isInProcess {
            work { value in result = value; done = true }
            let deadline = Date().addingTimeInterval(timeout)
            while !done, Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
            return done ? result : fail(command, -1712, late)   // errAETimeout
        }
        command.suspendExecution()
        let resume: (Any?) -> Void = { value in
            guard !done else { return }
            done = true
            command.resumeExecution(withResult: value)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            guard !done else { return }
            command.scriptErrorNumber = -1712
            command.scriptErrorString = late
            resume(nil)
        }
        work { value in DispatchQueue.main.async { resume(value) } }
        return nil
    }
}

// MARK: - The application: its windows, and Little Arc for `make new tab`

extension AppDelegate {
    @objc func application(_ sender: NSApplication, delegateHandlesKey key: String) -> Bool {
        key == "aircScriptWindows" || key == "aircScriptLittleArcTabs"
    }

    @objc var aircScriptWindows: [ScriptWindow] { ScriptWindow.all(self) }

    @objc(valueInAircScriptWindowsWithUniqueID:)
    func valueInAircScriptWindows(withUniqueID id: String) -> ScriptWindow? { aircScriptWindows.first { $0.uniqueID == id } }

    /// Arc's write-only `tabs` of the application: a tab made there opens in a Little Arc window.
    @objc var aircScriptLittleArcTabs: [ScriptTab] { [] }
}

// MARK: - make

/// Arc's `make`: a window (`with properties {incognito:true}` or `{mode:"incognito"}` for a private one), a tab in a
/// window or a space (`with properties {URL:...}`, shown), or a tab at the application (a Little Arc). Anything else
/// is Cocoa's own make.
@objc(AircScriptMakeCommand)
final class ScriptMakeCommand: NSCreateCommand {
    override func performDefaultImplementation() -> Any? {
        guard let app = NSApp.delegate as? AppDelegate else { return super.performDefaultImplementation() }
        let properties = evaluatedArguments?["KeyDictionary"] as? [String: Any] ?? [:]
        switch createClassDescription.className {
        case "window": return makeWindow(app, properties)
        case "tab": return makeTab(app, properties)
        default: return super.performDefaultImplementation()
        }
    }

    /// Where the object goes: `at …`, else the `tell` block's object, else the application.
    private var container: Any? {
        if let at = evaluatedArguments?["Location"] as? NSPositionalSpecifier {
            at.evaluate()
            return at.insertionContainer
        }
        // keySubjectAttr ('subj'), which Swift doesn't import.
        if let subject = appleEvent?.attributeDescriptor(forKeyword: AEKeyword(0x7375_626A)),
           subject.descriptorType != DescType(typeNull), let spec = NSScriptObjectSpecifier(descriptor: subject) {
            let value = spec.objectsByEvaluatingSpecifier
            return (value as? [Any])?.first ?? value
        }
        return nil
    }

    private func makeWindow(_ app: AppDelegate, _ properties: [String: Any]) -> Any? {
        let incognito = properties["isIncognito"] as? Bool == true || (properties["mode"] as? String)?.lowercased() == "incognito"
        guard incognito else {
            guard let c = app.openNewWindow(from: app.controller, commandBar: false) else {
                return ScriptingActions.fail(self, ScriptingActions.notPermitted, "Airc couldn’t open a window now.")
            }
            return ScriptWindow(c).objectSpecifier
        }
        return ScriptingActions.answer(self, timeout: 20, late: "The private window didn’t open in time.") { done in
            PrivateBrowsing.shared.open(app: app, from: nil) { w in done(w.flatMap { ScriptWindow(private: $0).objectSpecifier }) }
        }
    }

    private func makeTab(_ app: AppDelegate, _ properties: [String: Any]) -> Any? {
        guard let text = properties["URL"] as? String, let url = ScriptTab.url(text) else {
            // Arc's own answer.
            return ScriptingActions.fail(self, -1703, "Please provide a valid URL property for the make new tab command.")
        }
        switch container {
        case let w as ScriptWindow:
            if let p = w.privateController {
                p.openPage(url, foreground: true)
                return p.shownID.flatMap { ScriptTab(.privatePage($0), in: w).objectSpecifier }
            }
            guard let c = w.controller else { return nil }
            return openToday(url, in: c, spaceID: c.currentSpaceID, window: w)
        case let s as ScriptSpace:
            guard let c = s.window.controller else { return nil }
            return openToday(url, in: c, spaceID: s.spaceID, window: s.window)
        default:
            // The application: a Little Arc window, which isn't one of the windows (its tab has no specifier).
            _ = app.openLittleArc(url: url)
            return nil
        }
    }

    /// A new Today tab in `spaceID` (the window moves to that space), shown.
    private func openToday(_ url: URL, in c: WindowController, spaceID: String, window: ScriptWindow) -> Any? {
        if spaceID != c.currentSpaceID { c.switchToSpace(spaceID, animated: false) }
        guard let t = try? c.store.openTab(url: url.absoluteString, inSpace: spaceID) else {
            return ScriptingActions.fail(self, ScriptingActions.notPermitted, "Airc couldn’t open the tab.")
        }
        c.show(t.id)
        return ScriptTab(.today(t.id), in: window).objectSpecifier
    }
}

// MARK: - Window, space and tab commands

extension ScriptWindow {
    @objc func handleCloseScriptCommand(_ command: NSScriptCommand) -> Any? {
        if let p = privateController { p.closeWindow() } else { controller?.window.performClose(nil) }
        return nil
    }
}

extension ScriptSpace {
    @objc func handleFocusScriptCommand(_ command: NSScriptCommand) -> Any? {
        guard let c = window.controller, c.windowSpaces.contains(where: { $0.id == spaceID }) else {
            return ScriptingActions.fail(command, ScriptingActions.notLoaded, "That space isn’t in this window.")
        }
        if c.currentSpaceID != spaceID { c.switchToSpace(spaceID, animated: false) }
        return nil
    }
}

extension ScriptTab {
    @objc func handleSelectScriptCommand(_ command: NSScriptCommand) -> Any? {
        guard exists else { return ScriptingActions.fail(command, ScriptingActions.notLoaded, "The tab is gone.") }
        ScriptingActions.show(self)
        return nil
    }

    @objc func handleGoBackScriptCommand(_ command: NSScriptCommand) -> Any? { onPage(command) { $0.goBack() } }
    @objc func handleGoForwardScriptCommand(_ command: NSScriptCommand) -> Any? { onPage(command) { $0.goForward() } }
    @objc func handleReloadScriptCommand(_ command: NSScriptCommand) -> Any? { onPage(command) { $0.reload() } }
    @objc func handleStopScriptCommand(_ command: NSScriptCommand) -> Any? { onPage(command) { $0.stop() } }

    /// ⌘W's close: a Today tab closes, a pinned tab or Favorite unloads and keeps its row, a private page closes.
    @objc func handleCloseScriptCommand(_ command: NSScriptCommand) -> Any? {
        switch ref {
        case .privatePage(let id): window.privateController?.closeTab(id)
        case .item, .today:
            guard let t = liveTab, let app = NSApp.delegate as? AppDelegate else { return nil }
            (app.pageOwner(of: t.id) ?? window.controller)?.closeTab(t.id)
        }
        return nil
    }

    /// Arc's `execute … javascript`: only with View › Allow JavaScript from Apple Events on, never in a private window,
    /// in the tab's loaded page. The answer is text: a string as it is, anything else as JSON.
    @objc func handleExecuteScriptCommand(_ command: NSScriptCommand) -> Any? {
        guard AppleEventsJavaScript.isAllowed else {
            return ScriptingActions.fail(command, ScriptingActions.notPermitted, AppleEventsJavaScript.offMessage)
        }
        guard !isPrivate else {
            return ScriptingActions.fail(command, ScriptingActions.notPermitted, "Airc doesn’t run JavaScript from Apple Events in private windows.")
        }
        guard let source = command.evaluatedArguments?["javascript"] as? String else {
            return ScriptingActions.fail(command, -1715, "Give the JavaScript to run: execute … javascript \"…\".")
        }
        guard let page else {
            return ScriptingActions.fail(command, ScriptingActions.notLoaded, "The tab’s page isn’t loaded. Select it first.")
        }
        return ScriptingActions.answer(command, timeout: 30, late: "The page didn’t answer the JavaScript in time.") { done in
            page.evaluate(source) { value in done(AppleEventsJavaScript.text(value)) }
        }
    }

    private func onPage(_ command: NSScriptCommand, _ action: (EngineTab) -> Void) -> Any? {
        guard let page else {
            return ScriptingActions.fail(command, ScriptingActions.notLoaded, "The tab’s page isn’t loaded. Select it first.")
        }
        action(page)
        return nil
    }
}

// MARK: - Allow JavaScript from Apple Events

/// Arc's and Chrome's switch (View › Allow JavaScript from Apple Events): off until turned on, for every profile.
enum AppleEventsJavaScript {
    static var isAllowed: Bool { (NSApp.delegate as? AppDelegate)?.settings?.values.appleEventsJavaScript ?? false }

    static func toggle(_ app: AppDelegate?) { app?.settings.values.appleEventsJavaScript.toggle() }

    static let offMessage = "Executing JavaScript from Apple Events is turned off. To turn it on, choose View › Allow JavaScript from Apple Events."

    /// What `execute` answers: text, as Arc's dictionary says.
    static func text(_ value: Any?) -> Any? {
        guard let value, !(value is NSNull) else { return nil }
        switch value {
        case let s as String: return s
        case let n as NSNumber: return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
        default:
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
                return String(describing: value)
            }
            return String(decoding: data, as: UTF8.self)
        }
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import CoreAudio

/// `--script callrecorders` (both engines): what a call recorder or meeting-notes app (Granola, Otter, Krisp, Hex…)
/// can read from Airc while a page is in a call (artifacts/callrecorders/REPORT.md). The 'call' is a loopback page
/// titled like a Meet tab that plays a looping silent sound: no getUserMedia, no microphone, no camera. Recorders see
/// microphone use per process through CoreAudio, and Chromium runs input and output in the same audio-service
/// process, so the process playing the page's sound is the one a call's microphone would show up as.
///   - CoreAudio: the process that plays the page's sound is this app or answers to it (responsible process), and on
///     Chromium its bundle identifier is '<app id>.helper', Chrome's pattern, which recorders map to the app
///     (scripts/release/helper_ids.py);
///   - Accessibility (Chromium; WebKit's tree is out of process): the window's title, and a web area whose AXURL and
///     title are the page's (what Granola's meeting reader and Hex's AXURL fallback read);
///   - AppleScript, sent to this process (no Automation prompt): Chrome's `URL of active tab of front window`,
///     `title`, `active tab index`, and the same read with Chrome's raw class codes ('cwin', 'CrTb').
extension SnapshotRunner {
    func callRecordersScenario() {
        let engine = app?.engine.name.hasPrefix("Chromium") == true ? "chromium" : "webkit"
        let tag = "callrecorders \(engine)"
        var server: LocalPageServer?, port: UInt16 = 0
        var base: String { "http://127.0.0.1:\(port)" }
        let title = "Meet - Weekly sync"
        // 0.1 s of 8 kHz 8-bit silence (the 128 midpoint), looped: real output IO with nothing to hear.
        var wav = Data("RIFF".utf8)
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        wav += le32(36 + 800) + Data("WAVEfmt ".utf8) + le32(16) + le16(1) + le16(1) + le32(8000) + le32(8000) + le16(1) + le16(8)
        wav += Data("data".utf8) + le32(800) + Data(repeating: 128, count: 800)
        let page = """
            <!doctype html><title>\(title)</title><body style='font:18px -apple-system;margin:40px'><h1>\(title)</h1>
            <audio id=a autoplay loop src="data:audio/wav;base64,\(wav.base64EncodedString())"></audio>
            <script>document.getElementById('a').play().catch(function(){})</script></body>
            """
        step { done in
            server = LocalPageServer(pages: ["/call": page])
            server?.start { port = $0 ?? 0; done() }
            if server == nil { done() }
        }
        run { [self] in
            guard let t = try? c.store.openTab(url: base + "/call", inSpace: c.currentSpaceID) else {
                return check(false, "\(tag): the call page opens")
            }
            c.reloadAll(animated: false)
            c.show(t.id)
        }
        waitForPage()

        // CoreAudio: which process plays the call's sound, and what bundle identifier recorders see for it.
        var playing: [CallRecordersAudioProcess] = []
        step { [self] done in
            waitUntil({ playing = CallRecordersAudioProcess.ours().filter(\.runningOutput); return !playing.isEmpty }, timeout: 15) { done() }
        }
        run { [self] in
            let me = Bundle.main.bundleIdentifier ?? ""
            for p in CallRecordersAudioProcess.ours() {
                note("\(tag): coreaudio pid \(p.pid) \(p.name) bundleID \(p.bundleID) responsible \(p.responsible) output \(p.runningOutput) input \(p.runningInput)")
            }
            check(!playing.isEmpty, "\(tag): CoreAudio shows the call page's sound in this app or a process it is responsible for (\(playing.count))")
            if engine == "chromium" {
                let helpers = playing.filter { $0.pid != getpid() }
                check(!helpers.isEmpty && helpers.allSatisfy { $0.bundleID == me + ".helper" && $0.responsible == getpid() },
                      "\(tag): the audio service is '\(me).helper', Chrome's helper pattern (\(helpers.map(\.bundleID)))")
            } else {
                note("\(tag): WebKit plays through \(playing.map(\.bundleID)), the system's WebKit GPU process")
            }
        }

        // Accessibility, as an assistive client reads it. Chromium builds its tree when a client asks the app's role.
        run { _ = NSApp.accessibilityRole() }
        wait(2)
        run { [self] in
            let window: NSWindow = c.window
            let windowTitle = window.accessibilityTitle() ?? ""
            note("\(tag): window AXTitle '\(windowTitle)', AXDocument '\(window.accessibilityDocument() ?? "-")'")
            var areas: [(url: String, title: String)] = []
            var visited = 0
            func walk(_ node: Any, depth: Int) {
                guard depth < 60, visited < 20_000, let e = node as? NSAccessibilityProtocol else { return }
                visited += 1
                if e.accessibilityRole()?.rawValue == "AXWebArea" {
                    let o = node as AnyObject
                    let url = (o.accessibilityURL?() ?? nil)?.absoluteString ?? ""
                    let title = (o.accessibilityTitle?() ?? nil) ?? (o.accessibilityLabel?() ?? nil) ?? ""
                    areas.append((url, title))
                    return
                }
                for child in e.accessibilityChildren() ?? [] { walk(child, depth: depth + 1) }
            }
            walk(window, depth: 0)
            note("\(tag): web areas \(areas.map { "\($0.url) '\($0.title)'" }) after \(visited) elements")
            // WKWebView keeps its page's accessibility tree in the web content process, so an in-process walk ends at
            // the web view; only an outside client (with Accessibility access) can read WebKit's AXURL.
            guard engine == "chromium" else { return note("\(tag): WebKit's web area is out of process; not read in-process") }
            check(areas.contains { $0.url == base + "/call" },
                  "\(tag): a web area's AXURL is the call page's address (\(areas.map(\.url)))")
            check(areas.contains { $0.url == base + "/call" && $0.title == title },
                  "\(tag): that web area's AXTitle is the page's title (\(areas.map(\.title)))")
        }

        // AppleScript as recorders send it, compiled with this bundle's terms and handled in this process.
        run { [self] in
            let bundle = Bundle.main.bundleURL as CFURL
            let hfs = CFURLPathStyle(rawValue: 1).map { CFURLCopyFileSystemPath(bundle, $0) as String } ?? ""   // kCFURLHFSPathStyle
            func script(_ body: String) -> (text: String?, error: String?) {
                let source = "with timeout of 40 seconds\nusing terms from application \"\(hfs)\"\ntell current application\n\(body)\nend tell\nend using terms from\nend timeout"
                var info: NSDictionary?
                let r = NSAppleScript(source: source)?.executeAndReturnError(&info)
                if let info { return (nil, "\(info[NSAppleScript.errorNumber] ?? "?") \(info[NSAppleScript.errorMessage] ?? "")") }
                return (r?.stringValue, nil)
            }
            let url = script("get URL of active tab of front window"), name = script("get title of active tab of front window")
            check(url.text == base + "/call" && name.text == title,
                  "\(tag): Chrome's `URL`/`title of active tab of front window` (\(url.text ?? url.error ?? "-"), \(name.text ?? name.error ?? "-"))")
            let index = script("get active tab index of front window"), byIndex = script("get URL of tab (active tab index of front window) of front window")
            check(Int(index.text ?? "") ?? 0 >= 1 && byIndex.text == base + "/call",
                  "\(tag): Chrome's `active tab index` names the active tab (\(index.text ?? index.error ?? "-"), \(byIndex.text ?? byIndex.error ?? "-"))")
            let raw = script("get «class URL » of «class acTa» of «class cwin» 1"), count = script("count «class CrTb» of «class cwin» 1")
            check(raw.text == base + "/call" && (Int(count.text ?? "") ?? 0) >= 1,
                  "\(tag): Chrome's raw codes 'cwin', 'CrTb', 'acTa', 'URL ' (\(raw.text ?? raw.error ?? "-"), \(count.text ?? count.error ?? "-") tabs)")
        }
        run { server?.stop() }
    }
}

/// A CoreAudio process object (macOS 14+) that is this app or answers to it.
struct CallRecordersAudioProcess {
    var pid: pid_t, responsible: pid_t, bundleID: String, name: String, runningInput: Bool, runningOutput: Bool

    private typealias Responsible = @convention(c) (pid_t) -> pid_t
    private static let responsibleFor: Responsible? = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid")
        .map { unsafeBitCast($0, to: Responsible.self) }

    static func ours() -> [CallRecordersAudioProcess] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        func u32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
            var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var v: UInt32 = 0, s = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(object, &a, 0, nil, &s, &v) == noErr ? v : 0
        }
        func bundleID(_ object: AudioObjectID) -> String {
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var s = UInt32(MemoryLayout<CFString?>.size)
            var v: Unmanaged<CFString>?
            guard AudioObjectGetPropertyData(object, &a, 0, nil, &s, &v) == noErr, let id = v?.takeRetainedValue() else { return "" }
            return id as String
        }
        let me = getpid()
        return objects.compactMap { object in
            let pid = pid_t(bitPattern: u32(object, kAudioProcessPropertyPID))
            let responsible = responsibleFor?(pid) ?? -1
            guard pid == me || responsible == me else { return nil }
            var path = [CChar](repeating: 0, count: 4096)
            let name = proc_pidpath(pid, &path, 4096) > 0 ? (String(cString: path) as NSString).lastPathComponent : "?"
            return CallRecordersAudioProcess(pid: pid, responsible: responsible, bundleID: bundleID(object), name: name,
                                             runningInput: u32(object, kAudioProcessPropertyIsRunningInput) != 0,
                                             runningOutput: u32(object, kAudioProcessPropertyIsRunningOutput) != 0)
        }
    }
}
#endif

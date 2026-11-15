// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import ApplicationServices
import Carbon
import Darwin

// A launchd-owned process keeps TCC attribution on this signed helper, rather
// than on whichever freshly signed check app requests the operation.
let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("arcfork/tools/airc-ui-driver")
let socketPath = directory.appendingPathComponent("driver.sock").path
let limit = 4096

enum DriverError: Error { case invalid(String) }
func failure(_ message: String) -> [String: Any] { ["ok": false, "error": message] }
func number(_ value: String?) throws -> Double {
    guard let value, let n = Double(value), n.isFinite, abs(n) <= 100_000 else { throw DriverError.invalid("invalid coordinate") }
    return n
}
func permissions() -> [String: Any] {
    ["ok": true, "accessibility_trusted": AXIsProcessTrusted(),
     "input_monitoring_trusted": CGPreflightListenEventAccess(),
     "event_posting_trusted": CGPreflightPostEventAccess()]
}
func pipWindow() throws -> AXUIElement {
    guard AXIsProcessTrusted() else { throw DriverError.invalid("Accessibility permission is missing") }
    // Only the agent session's system PiP window is exposed; no arbitrary app AX.
    guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.PIPAgent" }) else {
        throw DriverError.invalid("PIPAgent is not running")
    }
    let element = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(element, 1)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement], windows.count == 1, let window = windows.first else {
        throw DriverError.invalid("expected exactly one PIPAgent window")
    }
    AXUIElementSetMessagingTimeout(window, 1)
    return window
}
func pipFrame(_ window: AXUIElement) throws -> [String: Any] {
    var position: CFTypeRef?, size: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
          AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
          let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else {
        throw DriverError.invalid("PIPAgent frame is unreadable")
    }
    var p = CGPoint.zero, s = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s) else {
        throw DriverError.invalid("PIPAgent frame has an unexpected type")
    }
    return ["ok": true, "x": p.x, "y": p.y, "width": s.width, "height": s.height]
}
// Resolve characters afresh for each command in the service, not in the caller.
// Only single plain/Shift keystrokes are supported; dead-key sequences and IME
// composition need text input rather than shortcut events and are refused.
struct KeyboardLayout {
    let data: Data
    let name: String
    init() throws {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            throw DriverError.invalid("current keyboard layout is unavailable; use --keycode for physical keys")
        }
        data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        if let rawName = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            name = Unmanaged<CFString>.fromOpaque(rawName).takeUnretainedValue() as String
        } else { name = "unknown" }
    }
    func character(_ code: CGKeyCode, shift: Bool) -> String? {
        data.withUnsafeBytes { buffer in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var dead: UInt32 = 0, length = 0
            var chars = [UniChar](repeating: 0, count: 8)
            let modifiers: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
            let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), modifiers,
                                        UInt32(LMGetKbdType()), 0, &dead, chars.count, &length, &chars)
            guard status == noErr, dead == 0, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
    func key(for character: String) throws -> (CGKeyCode, Bool) {
        for shifted in [false, true] {
            for code in UInt16(0)..<128 where self.character(code, shift: shifted) == character {
                return (code, shifted)
            }
        }
        throw DriverError.invalid("keyboard layout \(name) cannot type \(character) with a plain or Shift key; use --keycode for physical keys")
    }
}
struct KeyCommand {
    let key: CGKeyCode
    let modifiers: [(CGKeyCode, CGEventFlags)]
    let count: Int
    let pid: pid_t?
}
func keyCommand(_ args: [String]) throws -> KeyCommand {
    guard args.count >= 2, ["--key", "--keycode"].contains(args[0]) else { throw DriverError.invalid("expected --key character combo or --keycode numeric combo") }
    let parts = args[1].split(separator: "+", omittingEmptySubsequences: false).map(String.init)
    let namedKeys: [String: CGKeyCode] = ["return":36,"enter":36,"tab":48,"space":49,"delete":51,"esc":53,"escape":53,"home":115,"pageup":116,"forwarddelete":117,"end":119,"pagedown":121,"left":123,"right":124,"down":125,"up":126]
    // Include the NX device-dependent bits for these left-hand modifier keycodes,
    // as real flagsChanged events do (alongside the device-independent flags).
    func left(_ flag: CGEventFlags, _ deviceBit: UInt64) -> CGEventFlags {
        CGEventFlags(rawValue: flag.rawValue | deviceBit)
    }
    let modifierKeys: [String: (CGKeyCode, CGEventFlags)] = ["cmd":(55,left(.maskCommand, 0x08)),"shift":(56,left(.maskShift, 0x02)),"opt":(58,left(.maskAlternate, 0x20)),"ctrl":(59,left(.maskControl, 0x01))]
    guard let last = parts.last, !last.isEmpty else { throw DriverError.invalid("missing key") }
    let key: CGKeyCode
    var needsShift = false
    if args[0] == "--keycode" {
        guard last.allSatisfy({ $0.isASCII && $0.isNumber }), let code = UInt16(last), code < 128 else {
            throw DriverError.invalid("--keycode expects a decimal virtual keycode 0...127, optionally prefixed by modifiers (cmd+6)")
        }
        key = code
    } else if let code = namedKeys[last.lowercased()] { key = code }
    else {
        let character = last.lowercased() == "plus" ? "+" : last
        guard character.count == 1 else { throw DriverError.invalid("unknown key; use one layout character or a named key") }
        let resolved = try KeyboardLayout().key(for: character)
        key = resolved.0; needsShift = resolved.1
    }
    var modifiers: [(CGKeyCode, CGEventFlags)] = []
    for name in parts.dropLast() {
        guard let modifier = modifierKeys[name.lowercased()], !modifiers.contains(where: { $0.0 == modifier.0 }) else {
            throw DriverError.invalid("unknown or duplicate modifier; use cmd, opt, ctrl, shift")
        }
        modifiers.append(modifier)
    }
    if needsShift, !modifiers.contains(where: { $0.0 == 56 }) { modifiers.append(modifierKeys["shift"]!) }
    var count = 1, pid: pid_t?, seen = Set<String>(), i = 2
    while i < args.count {
        let option = args[i]
        guard i + 1 < args.count, seen.insert(option).inserted else { throw DriverError.invalid("missing or duplicate key option") }
        switch option {
        case "--repeat":
            guard let n = Int(args[i+1]), (1...20).contains(n) else { throw DriverError.invalid("repeat must be 1...20") }
            count = n
        case "--pid":
            guard let n = Int32(args[i+1]), n > 0 else { throw DriverError.invalid("pid must be a positive process ID") }
            pid = n
        default: throw DriverError.invalid("unsupported key option")
        }
        i += 2
    }
    return KeyCommand(key: key, modifiers: modifiers, count: count, pid: pid)
}
func keyEvents(_ command: KeyCommand) throws -> [CGEvent] {
    // Allocate the entire balanced sequence before posting anything.
    guard let source = CGEventSource(stateID: .hidSystemState) else { throw DriverError.invalid("could not create key source") }
    var events: [CGEvent] = [], flags = CGEventFlags()
    func append(_ code: CGKeyCode, _ down: Bool, _ type: CGEventType) throws {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else {
            throw DriverError.invalid("could not create key event")
        }
        event.type = type
        event.flags = flags
        events.append(event)
    }
    for (code, flag) in command.modifiers { flags.insert(flag); try append(code, true, .flagsChanged) }
    try append(command.key, true, .keyDown)
    try append(command.key, false, .keyUp)
    for (code, flag) in command.modifiers.reversed() { flags.remove(flag); try append(code, false, .flagsChanged) }
    return events
}
// This socket service has no AppKit event loop, and a target's accessibility tree
// need not be ready. Query the foreground PID synchronously via the public C
// Process Manager APIs. Swift hides these deprecated declarations; resolve their
// exported symbols, and fail closed if unavailable. No activation or AX request.
func foregroundProcessID() throws -> pid_t {
    let unavailable = DriverError.invalid("cannot verify the foreground process for --pid modifiers; focus the target window in the dedicated UI session, or omit --pid for foreground HID delivery")
    guard let library = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY | RTLD_LOCAL) else { throw unavailable }
    defer { dlclose(library) }
    guard let frontSymbol = dlsym(library, "GetFrontProcess"),
          let pidSymbol = dlsym(library, "GetProcessPID") else { throw unavailable }
    // Header signatures: OSErr (Int16), OSStatus (Int32), and two UInt32 PSN fields.
    let front = unsafeBitCast(frontSymbol, to: (@convention(c) (UnsafeMutableRawPointer) -> Int16).self)
    let processPID = unsafeBitCast(pidSymbol, to: (@convention(c) (UnsafeRawPointer, UnsafeMutablePointer<pid_t>) -> Int32).self)
    var serial = [UInt32](repeating: 0, count: 2), pid: pid_t = 0
    let found = serial.withUnsafeMutableBytes { bytes in
        front(bytes.baseAddress!) == 0 && processPID(bytes.baseAddress!, &pid) == 0
    }
    guard found, pid > 0 else { throw unavailable }
    return pid
}
// PID delivery is not activation. Require foreground ownership for modifier
// shortcut checks, rather than treating background posting as UI verification.
func validateKeyTarget(_ command: KeyCommand, frontmostPID: pid_t?) throws {
    if let pid = command.pid, !command.modifiers.isEmpty, frontmostPID != pid {
        throw DriverError.invalid("--pid \(pid) with modifiers requires the target app to be frontmost (foreground PID \(frontmostPID.map { String($0) } ?? "none")); activate its key window in the dedicated UI session, or omit --pid for foreground HID delivery. Use --key for layout characters or --keycode for physical keys")
    }
}
func sendKey(_ command: KeyCommand) throws {
    guard CGPreflightPostEventAccess(), CGPreflightListenEventAccess() else {
        throw DriverError.invalid("event posting or Input Monitoring permission is missing")
    }
    if let pid = command.pid, NSRunningApplication(processIdentifier: pid) == nil {
        throw DriverError.invalid("target process is not running")
    }
    if command.pid != nil && !command.modifiers.isEmpty {
        try validateKeyTarget(command, frontmostPID: foregroundProcessID())
    }
    let events = try keyEvents(command)
    for _ in 0..<command.count {
        for event in events {
            // Let WindowServer timestamp each delivery, including repeated presses.
            event.timestamp = 0
            if let pid = command.pid { event.postToPid(pid) }
            else { event.post(tap: .cghidEventTap) }
            Thread.sleep(forTimeInterval: 0.01)
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
}

// Reuse the key parser's modifier validation and device-dependent flags.
struct MouseCommand {
    let start: CGPoint
    let end: CGPoint?
    let modifiers: [(CGKeyCode, CGEventFlags)]
}
func mouseCommand(_ args: [String]) throws -> MouseCommand {
    guard let operation = args.first, operation == "--click" || operation == "--drag" else {
        throw DriverError.invalid("expected --click or --drag")
    }
    guard !args.contains("--pid") else {
        throw DriverError.invalid("--click/--drag use foreground HID delivery only; --pid is unsupported, including with --mods. Bring the target window forward in the dedicated UI session")
    }
    let base = operation == "--click" ? 3 : 5
    guard args.count == base || (args.count == base + 2 && args[base] == "--mods") else {
        throw DriverError.invalid("expected coordinates followed by optional --mods cmd,opt,shift,ctrl")
    }
    var modifiers: [(CGKeyCode, CGEventFlags)] = []
    if args.count > base {
        let combo = args[base + 1].replacingOccurrences(of: ",", with: "+")
        // Only comma separators are allowed here, including no empty components.
        guard !args[base + 1].contains("+") else { throw DriverError.invalid("use comma-separated modifiers") }
        modifiers = try keyCommand(["--keycode", combo + "+0"]).modifiers
    }
    let start = CGPoint(x: try number(args[1]), y: try number(args[2]))
    let end = base == 5 ? CGPoint(x: try number(args[3]), y: try number(args[4])) : nil
    return MouseCommand(start: start, end: end, modifiers: modifiers)
}
func mouseEvents(_ command: MouseCommand, original: CGPoint?) throws -> [CGEvent] {
    // Construct everything, including mouse-up and modifier releases, before posting.
    let keys = try keyEvents(KeyCommand(key: 0, modifiers: command.modifiers, count: 1, pid: nil))
    let n = command.modifiers.count
    var events = Array(keys.prefix(n))
    let flags = keys[n].flags
    guard let source = CGEventSource(stateID: .hidSystemState) else { throw DriverError.invalid("could not create mouse source") }
    func append(_ type: CGEventType, _ point: CGPoint, _ flags: CGEventFlags) throws {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
            throw DriverError.invalid("could not create mouse event")
        }
        event.flags = flags
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        events.append(event)
    }
    try append(.mouseMoved, command.start, flags)
    try append(.leftMouseDown, command.start, flags)
    if let end = command.end {
        for i in 1...30 {
            let f = min(1, Double(i) / 25)
            try append(.leftMouseDragged, CGPoint(x: command.start.x + (end.x-command.start.x)*f,
                                                 y: command.start.y + (end.y-command.start.y)*f), flags)
        }
    }
    try append(.leftMouseUp, command.end ?? command.start, flags)
    events.append(contentsOf: keys.suffix(n))
    if let original { try append(.mouseMoved, original, []) }
    return events
}
func sendMouse(_ command: MouseCommand) throws {
    guard CGPreflightPostEventAccess(), CGPreflightListenEventAccess() else {
        throw DriverError.invalid("event posting or Input Monitoring permission is missing")
    }
    let events = try mouseEvents(command, original: CGEvent(source: nil)?.location)
    for event in events {
        event.timestamp = 0
        event.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: event.type == .leftMouseDown ? 0.04 : (event.type == .leftMouseDragged ? 0.02 : 0.01))
    }
}

// Pointer movement uses HID so WindowServer updates the actual cursor and tracking areas.
// --pid is a foreground guard, not CGEventPostToPid (which does not move the cursor).
struct MoveCommand {
    let point: CGPoint
    var steps = 20
    var duration = 200
    var dwell = 0
    var pid: pid_t?
}
func moveCommand(_ args: [String]) throws -> MoveCommand {
    guard args.count >= 3, args.first == "--move" || args.first == "--hover" else {
        throw DriverError.invalid("expected --move/--hover x y")
    }
    var command = MoveCommand(point: CGPoint(x: try number(args[1]), y: try number(args[2])))
    var seen = Set<String>(), i = 3
    while i < args.count {
        let option = args[i]
        guard i + 1 < args.count, seen.insert(option).inserted, let n = Int(args[i + 1]) else {
            throw DriverError.invalid("missing, duplicate or non-integer movement option")
        }
        switch option {
        case "--steps" where (1...240).contains(n): command.steps = n
        case "--duration" where (0...2000).contains(n): command.duration = n
        case "--dwell" where args[0] == "--hover" && (0...2000).contains(n): command.dwell = n
        case "--pid" where n > 0 && n <= Int(Int32.max): command.pid = pid_t(n)
        default: throw DriverError.invalid("invalid movement option or bounds: " + option)
        }
        i += 2
    }
    guard args[0] != "--hover" || seen.contains("--dwell") else { throw DriverError.invalid("--hover requires --dwell ms") }
    return command
}
func moveEvents(_ command: MoveCommand, from start: CGPoint) throws -> [CGEvent] {
    guard let source = CGEventSource(stateID: .hidSystemState) else { throw DriverError.invalid("could not create mouse source") }
    return try (1...command.steps).map { step in
        let f = Double(step) / Double(command.steps)
        let point = CGPoint(x: start.x + (command.point.x-start.x)*f, y: start.y + (command.point.y-start.y)*f)
        guard let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
            throw DriverError.invalid("could not create mouse event")
        }
        event.flags = []
        return event
    }
}
func validateMoveTarget(_ command: MoveCommand, foreground: pid_t) throws {
    if let pid = command.pid, foreground != pid {
        throw DriverError.invalid("movement uses HID; --pid target must remain foreground in the dedicated UI session")
    }
}
func sendMove(_ command: MoveCommand) throws {
    guard CGPreflightPostEventAccess(), CGPreflightListenEventAccess() else {
        throw DriverError.invalid("event posting or Input Monitoring permission is missing")
    }
    guard let start = CGEvent(source: nil)?.location else { throw DriverError.invalid("could not read pointer position") }
    let events = try moveEvents(command, from: start)
    func checkTarget() throws {
        if command.pid != nil { try validateMoveTarget(command, foreground: foregroundProcessID()) }
    }
    try checkTarget()
    let began = ProcessInfo.processInfo.systemUptime
    for (i, event) in events.enumerated() {
        let deadline = began + Double(command.duration) / 1000 * Double(i + 1) / Double(events.count)
        Thread.sleep(forTimeInterval: max(0, deadline - ProcessInfo.processInfo.systemUptime))
        try checkTarget()
        event.timestamp = 0
        event.post(tap: .cghidEventTap)
    }
    // Intentionally leave the pointer there: restoring it would cancel the hover.
    Thread.sleep(forTimeInterval: Double(command.dwell) / 1000)
    try checkTarget()
}

func execute(_ args: [String]) -> [String: Any] {
    do {
        switch args.first {
        case "--move", "--hover":
            try sendMove(moveCommand(args))
            return ["ok": true]
        case "--key", "--keycode":
            try sendKey(keyCommand(args))
            return ["ok": true]
        case "--check" where args.count == 1: return permissions()
        case "--pip-frame" where args.count == 1: return try pipFrame(pipWindow())
        case "--pip-move" where args.count == 3:
            let window = try pipWindow()
            var point = CGPoint(x: try number(args[1]), y: try number(args[2]))
            guard AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &point)!) == .success else {
                throw DriverError.invalid("PIPAgent rejected position")
            }
            return ["ok": true]
        case "--click", "--drag":
            try sendMouse(mouseCommand(args))
            return ["ok": true]
        default: return failure("unsupported command or argument count")
        }
    } catch DriverError.invalid(let message) { return failure(message) }
    catch { return failure("operation failed") }
}
func address<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) rethrows -> T {
    var value = sockaddr_un()
    value.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketPath.utf8) + [0]
    precondition(bytes.count <= MemoryLayout.size(ofValue: value.sun_path))
    withUnsafeMutableBytes(of: &value.sun_path) { target in target.copyBytes(from: bytes) }
    value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return try withUnsafePointer(to: &value) { p in
        try p.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}
func readLine(_ fd: Int32) -> Data? {
    var data = Data(), byte: UInt8 = 0
    while data.count < limit {
        let count = Darwin.read(fd, &byte, 1)
        if count != 1 { return nil }
        if byte == 10 { return data }
        data.append(byte)
    }
    return nil
}
func send(_ data: Data, to fd: Int32) -> Bool {
    var line = data; line.append(10)
    return line.withUnsafeBytes { bytes in
        var sent = 0
        while sent < bytes.count {
            let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
            if n <= 0 { return false }
            sent += n
        }
        return true
    }
}
func configure(_ fd: Int32) {
    var timeout = timeval(tv_sec: 5, tv_usec: 0), yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
}
func serve() -> Never {
    signal(SIGPIPE, SIG_IGN)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { exit(1) }
    // launchd allows one instance. The socket is private to this user.
    unlink(socketPath)
    umask(0o077)
    guard address({ Darwin.bind(fd, $0, $1) }) == 0, listen(fd, 4) == 0 else { exit(1) }
    while true {
        let client = accept(fd, nil, nil)
        if client < 0 { continue }
        configure(client)
        var peerUID: uid_t = 0, peerGID: gid_t = 0
        if getpeereid(client, &peerUID, &peerGID) == 0, peerUID == getuid(),
           let data = readLine(client), let args = try? JSONSerialization.jsonObject(with: data) as? [String],
           let reply = try? JSONSerialization.data(withJSONObject: execute(args), options: [.sortedKeys]) {
            _ = send(reply, to: client)
        }
        close(client)
    }
}
func request(_ args: [String]) -> [String: Any] {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return failure("socket unavailable") }
    defer { close(fd) }
    configure(fd)
    guard address({ connect(fd, $0, $1) }) == 0 else { return failure("driver service is not running; run install.sh") }
    guard let data = try? JSONSerialization.data(withJSONObject: args), send(data, to: fd),
          let reply = readLine(fd), let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
        return failure("driver service did not answer within five seconds")
    }
    return object
}
var args = Array(CommandLine.arguments.dropFirst())
if args == ["--serve"] { serve() }
if args == ["--self-test"] {
    let movement = try! moveCommand(["--hover", "100", "-20", "--steps", "4", "--duration", "80", "--dwell", "500", "--pid", "123"])
    precondition((try? validateMoveTarget(movement, foreground: 124)) == nil)
    try! validateMoveTarget(movement, foreground: 123)
    let moves = try! moveEvents(movement, from: CGPoint(x: 0, y: 20))
    precondition(moves.count == 4 && moves.allSatisfy { $0.type == .mouseMoved && $0.flags.isEmpty })
    precondition(moves.first!.location == CGPoint(x: 25, y: 10) && moves.last!.location == movement.point)
    precondition(movement.duration == 80 && movement.dwell == 500 && movement.pid == 123)
    precondition(try! moveEvents(moveCommand(["--move", "0", "0", "--steps", "1", "--duration", "0"]), from: .zero).count == 1)
    for bad in [["--hover", "1", "2"], ["--move", "nan", "2"], ["--move", "1", "2", "--steps", "0"],
                ["--move", "1", "2", "--duration", "2001"], ["--hover", "1", "2", "--dwell", "-1"],
                ["--move", "1", "2", "--pid", "0"], ["--move", "1", "2", "--steps"],
                ["--move", "1", "2", "--steps", "2", "--steps", "3"], ["--move", "1", "2", "--mods", "cmd"]] {
        precondition((try? moveCommand(bad)) == nil)
    }
    print("PASS movement parsing, bounds and mouseMoved path (no posting)")
    precondition((try? number("nan")) == nil && (try? number("100001")) == nil)
    precondition((try? number("-42.5")) == -42.5)
    precondition(execute(["--drag"])["ok"] as? Bool == false)
    precondition(execute(["--unknown"])["ok"] as? Bool == false)
    let command = try! keyCommand(["--keycode", "ctrl+cmd+3", "--repeat", "2", "--pid", "123"])
    precondition(command.key == 3 && command.count == 2 && command.pid == 123)
    let events = try! keyEvents(command)
    precondition(events.map(\.type) == [.flagsChanged, .flagsChanged, .keyDown, .keyUp, .flagsChanged, .flagsChanged])
    precondition(events[2].flags.rawValue == (CGEventFlags.maskControl.rawValue | CGEventFlags.maskCommand.rawValue | 0x09) && events.last!.flags.isEmpty)
    precondition(events.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [59,55,3,3,55,59])
    for args in [["--key"], ["--key", ""], ["--key", "cmd+cmd+n"], ["--key", "cmd+wat"],
                 ["--key", "esc", "--repeat", "0"], ["--key", "esc", "--repeat", "21"],
                 ["--key", "esc", "--pid", "-1"], ["--key", "esc", "--repeat"],
                 ["--key", "esc", "--pid", "1", "--pid", "2"], ["--key", "esc", "--other", "1"]] {
        precondition((try? keyCommand(args)) == nil)
    }
    let layout = try! KeyboardLayout()
    let z = try! keyCommand(["--key", "cmd+z"])
    let zEvents = try! keyEvents(z)
    precondition(layout.character(z.key, shift: z.modifiers.contains { $0.0 == 56 }) == "z")
    precondition(zEvents.filter { $0.type == .keyDown || $0.type == .keyUp }.allSatisfy {
        $0.getIntegerValueField(.keyboardEventKeycode) == Int64(z.key) && $0.flags.contains(.maskCommand)
    })
    if layout.name == "com.apple.keylayout.Austrian" { precondition(z.key == 16) }
    precondition(try! keyCommand(["--keycode", "cmd+6"]).key == 6)
    precondition(try! keyCommand(["--keycode", "0"]).key == 0)
    precondition(try! keyCommand(["--keycode", "127"]).key == 127)
    for combo in ["-1", "128", "65536", "cmd+z", "6.5", "cmd+cmd+6"] {
        precondition((try? keyCommand(["--keycode", combo])) == nil)
    }
    for character in ["z", "Z", "y", "Y", "/", ":", "+"] {
        let command = try! keyCommand(["--key", character == "+" ? "plus" : character])
        precondition(layout.character(command.key, shift: command.modifiers.contains { $0.0 == 56 }) == character)
    }
    let shiftedZ = try! keyCommand(["--key", "cmd+shift+Z"])
    precondition(shiftedZ.modifiers.filter { $0.0 == 56 }.count == 1)
    print("PASS current layout \(layout.name): cmd+z keyDown/keyUp code=\(z.key), character=z; physical cmd+6 stays code=6 (no posting)")
    precondition(try! keyCommand(["--key", "esc"]).key == 53)
    precondition(try! keyCommand(["--key", "return"]).key == 36)
    for operation in ["--click", "--drag"] {
        let coords = operation == "--click" ? ["10", "20"] : ["10", "20", "80", "90"]
        for mods in [[], ["--mods", "cmd,opt"], ["--mods", "cmd,opt,shift,ctrl"]] {
            let command = try! mouseCommand([operation] + coords + mods)
            let events = try! mouseEvents(command, original: CGPoint(x: 4, y: 5))
            let n = command.modifiers.count
            precondition(events.prefix(n).allSatisfy { $0.type == .flagsChanged })
            let mouse = events.filter { [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp].contains($0.type) }
            let flags = command.modifiers.reduce(CGEventFlags()) { $0.union($1.1) }
            precondition(mouse.dropLast().allSatisfy { $0.flags == flags })
            precondition(mouse[1].type == .leftMouseDown && mouse[mouse.count-2].type == .leftMouseUp)
            precondition(mouse[mouse.count-2].location == (command.end ?? command.start))
            precondition(events.last!.flags.isEmpty && events.last!.location == CGPoint(x: 4, y: 5))
            let releases = events.suffix(n+1).dropLast()
            precondition(releases.map { $0.getIntegerValueField(.keyboardEventKeycode) } == command.modifiers.reversed().map { Int64($0.0) })
            precondition(releases.last?.flags.isEmpty ?? true)
            var accumulated = CGEventFlags()
            for (event, modifier) in zip(events.prefix(n), command.modifiers) {
                accumulated.insert(modifier.1)
                precondition(event.flags == accumulated)
            }
            for (event, modifier) in zip(releases, command.modifiers.reversed()) {
                accumulated.remove(modifier.1)
                precondition(event.type == .flagsChanged && event.flags == accumulated)
            }
            precondition(events.filter { $0.type == .leftMouseDragged }.count == (operation == "--drag" ? 30 : 0))
        }
        for invalid in [["--mods", ""], ["--mods", "cmd,cmd"], ["--mods", "cmd,"], ["--mods", "wat"],
                        ["--mods", "cmd+opt"], ["--mods"], ["--mods", "cmd", "extra"], ["--pid", "1"]] {
            precondition((try? mouseCommand([operation] + coords + invalid)) == nil)
        }
    }
    precondition((try? mouseCommand(["--click", "nan", "1"])) == nil)
    precondition((try? mouseCommand(["--drag", "1", "2", "3"])) == nil)
    let targeted = try! keyCommand(["--key", "cmd+z", "--pid", "123"])
    try! validateKeyTarget(targeted, frontmostPID: 123)
    for frontmost in [pid_t(456), nil] as [pid_t?] {
        do { try validateKeyTarget(targeted, frontmostPID: frontmost); preconditionFailure("background modifier target accepted") }
        catch DriverError.invalid(let message) { precondition(message.contains("frontmost") && message.contains("--keycode")) }
        catch { preconditionFailure("unexpected validation error") }
    }
    try! validateKeyTarget(keyCommand(["--keycode", "6", "--pid", "123"]), frontmostPID: 456)
    try! validateKeyTarget(keyCommand(["--key", "cmd+z"]), frontmostPID: nil)
    print("PASS PID modifier foreground policy; plain PID and HID unchanged (no posting)")
    print("PASS mouse parsing, flags, balanced click/drag sequences and pointer restoration (no posting)")
    print("PASS key parsing and balanced event sequence (no posting)")
    print("PASS argument validation; invalid commands perform no UI operation")
    exit(0)
}
let jsonOnly = args.first == "--json"
if jsonOnly { args.removeFirst() }
let result = request(args)
if !jsonOnly && args == ["--check"] && result["ok"] as? Bool == true {
    for key in ["accessibility_trusted", "input_monitoring_trusted", "event_posting_trusted"] {
        print(key.replacingOccurrences(of: "_trusted", with: "") + " trusted=" + ((result[key] as? Bool == true) ? "true" : "false"))
    }
} else if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
let granted = args != ["--check"] || ["accessibility_trusted", "input_monitoring_trusted", "event_posting_trusted"].allSatisfy { result[$0] as? Bool == true }
exit(result["ok"] as? Bool == true && granted ? 0 : 1)

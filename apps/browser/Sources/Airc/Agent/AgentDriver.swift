// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // agentspike: a dev-build prototype (docs/agent-ready.md); public builds compile none of Agent/
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A mouse event in page coordinates (CSS pixels from the page's top left, which are the agent window's points).
struct AgentMouse {
    enum Kind { case moved, pressed, released }
    enum Button: String { case none, left, middle, right }
    var kind: Kind
    var point: CGPoint
    var button: Button = .none
    var clickCount = 1
    var modifiers: AgentModifiers = []
    /// Buttons held during a move (a drag).
    var held: Button = .none
}

struct AgentModifiers: OptionSet {
    let rawValue: Int
    static let alt = AgentModifiers(rawValue: 1)       // CDP's bits
    static let ctrl = AgentModifiers(rawValue: 2)
    static let meta = AgentModifiers(rawValue: 4)
    static let shift = AgentModifiers(rawValue: 8)

    var appKit: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if contains(.alt) { f.insert(.option) }
        if contains(.ctrl) { f.insert(.control) }
        if contains(.meta) { f.insert(.command) }
        if contains(.shift) { f.insert(.shift) }
        return f
    }

    /// "shift", "ctrl+shift", "super"… (the computer-use tools' modifier names).
    static func parse(_ s: String?) -> AgentModifiers? {
        guard let s, !s.isEmpty else { return [] }
        var m: AgentModifiers = []
        for part in s.lowercased().split(separator: "+") {
            switch part.trimmingCharacters(in: .whitespaces) {
            case "shift": m.insert(.shift)
            case "ctrl", "control": m.insert(.ctrl)
            case "alt", "option", "opt": m.insert(.alt)
            case "super", "cmd", "command", "meta", "win": m.insert(.meta)
            default: return nil
            }
        }
        return m
    }
}

/// One key: the DOM's key and code, Windows' virtual key code (CDP), the Mac key code (AppKit) and the text it types.
struct AgentKey {
    var key: String
    var code: String
    var windowsCode: Int
    var macCode: UInt16
    var text: String?

    private static let table: [String: AgentKey] = {
        var t: [String: AgentKey] = [
            "return": AgentKey(key: "Enter", code: "Enter", windowsCode: 13, macCode: 36, text: "\r"),
            "enter": AgentKey(key: "Enter", code: "Enter", windowsCode: 13, macCode: 36, text: "\r"),
            "kp_enter": AgentKey(key: "Enter", code: "NumpadEnter", windowsCode: 13, macCode: 76, text: "\r"),
            "tab": AgentKey(key: "Tab", code: "Tab", windowsCode: 9, macCode: 48, text: "\t"),
            "escape": AgentKey(key: "Escape", code: "Escape", windowsCode: 27, macCode: 53, text: nil),
            "esc": AgentKey(key: "Escape", code: "Escape", windowsCode: 27, macCode: 53, text: nil),
            "backspace": AgentKey(key: "Backspace", code: "Backspace", windowsCode: 8, macCode: 51, text: nil),
            "delete": AgentKey(key: "Delete", code: "Delete", windowsCode: 46, macCode: 117, text: nil),
            "space": AgentKey(key: " ", code: "Space", windowsCode: 32, macCode: 49, text: " "),
            "up": AgentKey(key: "ArrowUp", code: "ArrowUp", windowsCode: 38, macCode: 126, text: nil),
            "down": AgentKey(key: "ArrowDown", code: "ArrowDown", windowsCode: 40, macCode: 125, text: nil),
            "left": AgentKey(key: "ArrowLeft", code: "ArrowLeft", windowsCode: 37, macCode: 123, text: nil),
            "right": AgentKey(key: "ArrowRight", code: "ArrowRight", windowsCode: 39, macCode: 124, text: nil),
            "home": AgentKey(key: "Home", code: "Home", windowsCode: 36, macCode: 115, text: nil),
            "end": AgentKey(key: "End", code: "End", windowsCode: 35, macCode: 119, text: nil),
            "page_up": AgentKey(key: "PageUp", code: "PageUp", windowsCode: 33, macCode: 116, text: nil),
            "page_down": AgentKey(key: "PageDown", code: "PageDown", windowsCode: 34, macCode: 121, text: nil),
        ]
        t["arrowup"] = t["up"]; t["arrowdown"] = t["down"]; t["arrowleft"] = t["left"]; t["arrowright"] = t["right"]
        t["pageup"] = t["page_up"]; t["pagedown"] = t["page_down"]; t["prior"] = t["page_up"]; t["next"] = t["page_down"]
        let f: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, code) in f.enumerated() {
            t["f\(i + 1)"] = AgentKey(key: "F\(i + 1)", code: "F\(i + 1)", windowsCode: 112 + i, macCode: code, text: nil)
        }
        return t
    }()

    /// US key codes, for the code a page sees; WebKit keeps the characters, Chromium's DevTools input takes key and code.
    private static let macLetter: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
        "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50, " ": 49,
    ]

    /// A key name ("Return", "a", "F5") or one printable character.
    static func named(_ name: String) -> AgentKey? {
        if let k = table[name.lowercased()] { return k }
        guard name.count == 1, let ch = name.first else { return nil }
        return character(ch)
    }

    static func character(_ ch: Character) -> AgentKey {
        let lower = Character(ch.lowercased())
        let s = String(ch)
        if ch.isLetter, ch.isASCII {
            let up = s.uppercased()
            return AgentKey(key: s, code: "Key" + up, windowsCode: Int(up.unicodeScalars.first!.value),
                            macCode: macLetter[lower] ?? 0, text: s)
        }
        if ch.isNumber, ch.isASCII {
            return AgentKey(key: s, code: "Digit" + s, windowsCode: Int(s.unicodeScalars.first!.value),
                            macCode: macLetter[ch] ?? 0, text: s)
        }
        if ch == "\n" || ch == "\r" { return table["return"]! }
        if ch == "\t" { return table["tab"]! }
        return AgentKey(key: s, code: "", windowsCode: 0, macCode: macLetter[ch] ?? 0, text: s)
    }
}

enum AgentDriverError: Error, CustomStringConvertible {
    case failed(String)
    var description: String { if case .failed(let s) = self { return s }; return "failed" }
}

/// What an engine does for agent windows: keep the page live off screen, deliver input to the page without the window
/// ever being key, and picture the page with the engine's own capture (never Screen Recording).
protocol AgentPageDriver: AnyObject {
    var engineName: String { get }
    /// "native" (trusted engine input) or "script" (DOM events from a page script), per kind of input, for reports.
    var inputPaths: [String: String] { get }
    /// Once per tab in an agent window. `visible`: keep the page visible and focused although nothing shows it.
    func prepare(_ tab: EngineTab, in window: NSWindow, visible: Bool, completion: @escaping (String?) -> Void)
    func release(_ tab: EngineTab)
    /// The page as the engine draws it, at device pixels.
    func capture(_ tab: EngineTab, completion: @escaping (Result<CGImage, AgentDriverError>) -> Void)
    func mouse(_ tab: EngineTab, _ e: AgentMouse, completion: @escaping (String?) -> Void)
    func key(_ tab: EngineTab, _ k: AgentKey, down: Bool, modifiers: AgentModifiers, completion: @escaping (String?) -> Void)
    func insertText(_ tab: EngineTab, _ text: String, completion: @escaping (String?) -> Void)
    func scroll(_ tab: EngineTab, at p: CGPoint, dx: CGFloat, dy: CGFloat, modifiers: AgentModifiers,
                completion: @escaping (String?) -> Void)
    /// A script in a world the page can't see where possible; answers its value (a JSON string when the script
    /// returns one, parsed).
    func evaluate(_ tab: EngineTab, _ script: String, completion: @escaping (Any?) -> Void)
    /// select all, undo, redo: editing commands that need no pasteboard.
    func editCommand(_ tab: EngineTab, _ command: String, completion: @escaping (String?) -> Void)
    /// Before an agent's page closes: no "Leave site?" (nobody would see it), in the page's own world.
    func dropUnloadQuestion(_ tab: EngineTab, completion: @escaping () -> Void)
    /// AgentPageScripts.guards in the shown document (idempotent): after a load, and before a press.
    func installGuards(_ tab: EngineTab, completion: @escaping () -> Void)
}

extension AgentPageDriver {
    /// A right click without the engine's context menu, which is a modal menu on the owner's screen: the page gets
    /// the mouse events and `contextmenu`, from a script.
    func scriptContextClick(_ tab: EngineTab, at p: CGPoint, completion: @escaping (String?) -> Void) {
        let js = """
        (function(x,y){var t=document.elementFromPoint(x,y)||document.body;
        function f(type,b){t.dispatchEvent(new MouseEvent(type,{bubbles:true,cancelable:true,composed:true,clientX:x,clientY:y,button:2,buttons:b,view:window}));}
        f('mousedown',2);f('mouseup',0);f('contextmenu',0);return JSON.stringify({ok:true});})(\(p.x),\(p.y))
        """
        evaluate(tab, js) { _ in completion(nil) }
    }

    /// Scrolls the scrollable element under the point (or the page), from a script: the fallback where the engine's
    /// own wheel input isn't available.
    func scriptScroll(_ tab: EngineTab, at p: CGPoint, dx: CGFloat, dy: CGFloat, completion: @escaping (String?) -> Void) {
        let js = """
        (function(x,y,dx,dy){var e=document.elementFromPoint(x,y);
        while(e&&e!==document.body&&e!==document.documentElement){var s=getComputedStyle(e);
        if((/(auto|scroll)/.test(s.overflowY)&&e.scrollHeight>e.clientHeight)||(/(auto|scroll)/.test(s.overflowX)&&e.scrollWidth>e.clientWidth)){e.scrollBy(dx,dy);return JSON.stringify({el:true});}
        e=e.parentElement;}window.scrollBy(dx,dy);return JSON.stringify({el:false});})(\(p.x),\(p.y),\(dx),\(dy))
        """
        evaluate(tab, js) { _ in completion(nil) }
    }
}

enum AgentImages {
    /// The image at exactly `size` pixels (an agent's screenshot is in the window's points).
    static func scaled(_ image: CGImage, to size: CGSize, crop: CGRect? = nil) -> CGImage? {
        let source = crop.flatMap { image.cropping(to: $0) } ?? image
        if crop == nil, source.width == Int(size.width), source.height == Int(size.height) { return source }
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(source, in: CGRect(origin: .zero, size: size))
        return ctx.makeImage()
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// The colour at a point (top-left origin), for checks.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        guard let p = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return (Int(p[0]), Int(p[1]), Int(p[2]))
    }
}

/// A script's answer: scripts return JSON.stringify(…), which engines hand back as a string (or, some, parsed).
func agentJSON(_ value: Any?) -> [String: Any]? {
    if let d = value as? [String: Any] { return d }
    if let s = value as? String, let data = s.data(using: .utf8) { return try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
    return nil
}
#endif

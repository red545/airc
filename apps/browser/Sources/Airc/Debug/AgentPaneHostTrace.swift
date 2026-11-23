// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import QuartzCore

/// cardflicker: which layer and which context the live card shows at each moment, next to the engine's own hosts.
/// A main run-loop observer right after Core Animation's commit (order above CA's 2 000 000) writes a line whenever
/// what was just committed changed: the agent window's CALayerHosts (context id, size, the view that owns them) and
/// the card's hosted context. Times are on the flicker probe's clock, so the lines sit between its pictures.
final class AgentPaneHostTrace {
    private(set) var lines: [(t: Double, what: String)] = []
    private var observer: CFRunLoopObserver?
    private var last = ""
    private let clock: () -> Double
    private let agentWindow: () -> NSWindow?
    private let card: () -> String

    init(clock: @escaping () -> Double, agentWindow: @escaping () -> NSWindow?, card: @escaping () -> String) {
        self.clock = clock
        self.agentWindow = agentWindow
        self.card = card
    }

    func note(_ what: String) { lines.append((clock(), what)) }

    func start() {
        let o = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_000_500) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        observer = o
        CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
        sample()
    }

    func stop() {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
    }

    private func sample() {
        let s = "engine [\(Self.hosts(in: agentWindow()))] card [\(card())]"
        guard s != last else { return }
        last = s
        lines.append((clock(), s))
    }

    /// "ctx 123 1280x800 in RenderWidgetHostViewCocoa@4f2a (hidden)" per host, in tree order.
    static func hosts(in window: NSWindow?) -> String {
        guard let root = window?.contentView?.layer else { return "no window" }
        var out: [String] = []
        func walk(_ l: CALayer, _ view: String, _ hidden: Bool) {
            var v = view
            if let owner = l.delegate as? NSView { v = "\(type(of: owner))@\(String(UInt(bitPattern: ObjectIdentifier(owner).hashValue) % 0x10000, radix: 16))" }
            let h = hidden || l.isHidden || l.opacity == 0
            if NSStringFromClass(type(of: l)) == "CALayerHost" {
                let id = (l.value(forKey: "contextId") as? NSNumber)?.stringValue ?? "?"
                out.append("ctx \(id) \(Int(l.bounds.width))x\(Int(l.bounds.height)) in \(v)\(h ? " (hidden)" : "")")
            }
            for s in l.sublayers ?? [] { walk(s, v, h) }
        }
        walk(root, "content", false)
        return out.isEmpty ? "none" : out.joined(separator: ", ")
    }

    var text: String { lines.map { String(format: "%.4f\t%@", $0.t, $0.what) }.joined(separator: "\n") + "\n" }
}
#endif

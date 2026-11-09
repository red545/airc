// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
import ObjectiveC.runtime

/// Evidence is collected while input is in flight, not inferred from an assertion's wording.
/// NSPasteboard has no public API for the writer's pid. Our fixtures publish a run/pid marker;
/// an unmarked writer is reported as unknown, never attributed to the frontmost app.
final class UICheckAttempt {
    static let ownerType = NSPasteboard.PasteboardType("org.airc.test.fixture-owner")
    static let token = "pid=\(getpid());run=\(UUID().uuidString)"
    // Observe writes in THIS process (including Chromium's browser-side ClipboardMac). Unlike guessing from the
    // text, this distinguishes a regressed copy of the wrong value from a different process writing the clipboard.
    private static var ownCounts: Set<Int> = []
    private static var installed = false
    static func observeWrites() {
        guard !installed else { return }
        installed = true
        func recorded(_ pb: NSPasteboard) {
            if pb.name == .general { ownCounts.insert(pb.changeCount) }
        }
        if let m = class_getInstanceMethod(NSPasteboard.self, #selector(NSPasteboard.clearContents)) {
            typealias F = @convention(c) (NSPasteboard, Selector) -> Int
            let original = unsafeBitCast(method_getImplementation(m), to: F.self)
            let block: @convention(block) (NSPasteboard) -> Int = { pb in
                let result = original(pb, #selector(NSPasteboard.clearContents)); recorded(pb); return result
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        for selector in [#selector(NSPasteboard.declareTypes(_:owner:)), #selector(NSPasteboard.addTypes(_:owner:))] {
            guard let m = class_getInstanceMethod(NSPasteboard.self, selector) else { continue }
            typealias F = @convention(c) (NSPasteboard, Selector, NSArray, AnyObject?) -> Int
            let original = unsafeBitCast(method_getImplementation(m), to: F.self)
            let block: @convention(block) (NSPasteboard, NSArray, AnyObject?) -> Int = { pb, types, owner in
                let result = original(pb, selector, types, owner); recorded(pb); return result
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        for selector in [#selector(NSPasteboard.setString(_:forType:)), #selector(NSPasteboard.setData(_:forType:))] {
            guard let m = class_getInstanceMethod(NSPasteboard.self, selector) else { continue }
            typealias F = @convention(c) (NSPasteboard, Selector, AnyObject?, NSString) -> ObjCBool
            let original = unsafeBitCast(method_getImplementation(m), to: F.self)
            let block: @convention(block) (NSPasteboard, AnyObject?, NSString) -> ObjCBool = { pb, data, type in
                let result = original(pb, selector, data, type); recorded(pb); return result
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        if let m = class_getInstanceMethod(NSPasteboard.self, #selector(NSPasteboard.writeObjects(_:))) {
            typealias F = @convention(c) (NSPasteboard, Selector, NSArray) -> ObjCBool
            let original = unsafeBitCast(method_getImplementation(m), to: F.self)
            let block: @convention(block) (NSPasteboard, NSArray) -> ObjCBool = { pb, items in
                let result = original(pb, #selector(NSPasteboard.writeObjects(_:)), items); recorded(pb); return result
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
    }
    static var ownsCurrentContents: Bool { ownCounts.contains(NSPasteboard.general.changeCount) }
    static var lastOwnedCount: Int?
    static var lastFixture: [[NSPasteboard.PasteboardType: Data]]?
    static func markFixture() {
        NSPasteboard.general.setString(token, forType: ownerType)
        lastOwnedCount = NSPasteboard.general.changeCount
        lastFixture = SnapshotRunner.pasteboardItems()
    }
    static var mayRestorePasteboard: Bool {
        NSPasteboard.general.changeCount == lastOwnedCount
            && NSPasteboard.general.string(forType: ownerType) == token
    }
    static func ownedFixture() -> [[NSPasteboard.PasteboardType: Data]]? {
        mayRestorePasteboard ? SnapshotRunner.pasteboardItems() : nil
    }

    weak var window: NSWindow?
    var retry = false
    var results: [(Bool, String)] = []
    private(set) var inputDelivered = false
    private var deliveries: [Bool] = []
    func recordInputDelivery(_ delivered: Bool) {
        deliveries.append(delivered)
        inputDelivered = deliveries.allSatisfy { $0 }
    }
    var needsKeyWindow = true
    var needsUncoveredWindow = true
    var point: NSPoint?
    var monitorsPasteboard = false
    var pasteboardReadOnly = false
    let pasteboardBefore = NSPasteboard.general.changeCount
    private let ownerBefore = NSPasteboard.general.string(forType: ownerType)
    private var timer: Timer?
    private var clipboardEvidence: String?
    private var focusEvidence: String?
    /// The focus evidence is a state a retry a second later won't change: the screen locked, our window off the active
    /// Space, or another process's window over ours. Such a case is FAIL-ENV at once (no retry, no time spent).
    private(set) var persistentFocusEvidence = false

    init(window: NSWindow?) {
        self.window = window
        timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in self?.sample() }
    }
    func stop() { timer?.invalidate(); timer = nil }
    func sample() {
        let pb = NSPasteboard.general
        let owner = pb.string(forType: Self.ownerType)
        let count = pb.changeCount
        let replacedFixture = pasteboardReadOnly && Self.lastOwnedCount.map { $0 != count } == true
        if monitorsPasteboard, (count != pasteboardBefore || replacedFixture), !Self.ownCounts.contains(count) {
            clipboardEvidence = "pasteboard changeCount \(pasteboardBefore) → \(count), fixture count \(Self.lastOwnedCount.map(String.init) ?? "none"), "
                + "writer outside pid \(getpid()); owner \(ownerBefore ?? "unknown") → \(owner ?? "unknown (untagged)")"
        }
        if let block = focusBlock { focusEvidence = block.reason; persistentFocusEvidence = block.persistent }
    }
    var invalidClipboard: Bool { clipboardEvidence != nil }
    /// Whether retrying could help: another writer on the clipboard, or a window that only wasn't key. Not when the
    /// screen is locked, the window is on another Space or under another app's window: those stay as they are.
    var retryCouldHelp: Bool { clipboardEvidence != nil || !persistentFocusEvidence }
    var interference: String? {
        if let clipboardEvidence { return clipboardEvidence }
        // A delivered key proves the stand-in worked. Do not excuse a broken browser command just because open -g
        // made the real window non-key. Same-process window stacking errors also remain real failures.
        return inputDelivered ? nil : focusEvidence
    }
    private var focusBlock: (reason: String, persistent: Bool)? {
        guard let w = window else { return nil }
        let front = NSWorkspace.shared.frontmostApplication
        let owner = "front owner \(front?.localizedName ?? "unknown") pid \(front?.processIdentifier ?? -1); target window \(w.windowNumber) pid \(getpid())"
        if SnapshotRunner.screenLocked { return ("screen locked; \(owner)", true) }
        if !w.isOnActiveSpace { return ("our window isn't on the active Space; \(owner)", true) }
        let top = NSWindow.windowNumber(at: w.convertPoint(toScreen: point ?? NSPoint(x: w.contentView?.bounds.midX ?? 0, y: w.contentView?.bounds.midY ?? 0)), belowWindowWithWindowNumber: 0)
        let info = SnapshotRunner.windowInfo(top)
        if needsUncoveredWindow, top != 0, top != w.windowNumber, info.pid != getpid() {
            return ("another process's window is in front: \(info.text); \(owner)", true)
        }
        if needsKeyWindow, !w.isKeyWindow { return ("our window isn't key; \(owner)", false) }
        return nil
    }
}
#endif

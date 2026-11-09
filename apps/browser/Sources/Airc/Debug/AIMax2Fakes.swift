// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

// Fake models for `--script askpage`, `linkpreview` and `tidydownloads` (AskPageCheck.swift, LinkPreviewCheck.swift,
// TidyDownloadsCheck.swift): answers from tables, every request recorded, and a way to hang (ignoring cancellation, as
// a stuck model would). They run the same with or without Apple Intelligence; the checks' last steps time the real
// on-device model when this Mac has it.

final class ScriptedAskModel: AskPageModel, AskPageVerifier, @unchecked Sendable {
    struct Answer {
        var parts: [String]
        var quotes: [String]
    }
    private let lock = NSLock()
    private var requests: [AskPageRequest] = []
    var answers: [String: Answer] = [:]
    var hang: Set<String> = []
    /// Questions whose stream fails after its first part (as a guided answer that fails to decode partway).
    var failAfterFirst: Set<String> = []
    /// What the check of an answer finds, by question (none: the check fails, so the answer isn't confirmed).
    var evidence: [String: AskPageEvidence] = [:]
    private var checks: [AskPageCheckRequest] = []
    var checked: [AskPageCheckRequest] { lock.withLock { checks } }
    /// Questions whose model hangs after its last part until cancelled (as a check under way when the profile goes).
    var checkHangs: Set<String> = []

    func check(_ request: AskPageCheckRequest) async throws -> AskPageEvidence {
        lock.withLock { checks.append(request) }
        if checkHangs.contains(request.question) {
            try await Task.sleep(nanoseconds: 20_000_000_000)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        guard let e = evidence[request.question] else { throw CocoaError(.featureUnsupported) }
        return e
    }
    var delay: TimeInterval = 0.12

    var asked: [AskPageRequest] { lock.withLock { requests } }

    func answer(_ request: AskPageRequest) -> AsyncThrowingStream<AskPagePartial, Error> {
        lock.withLock { requests.append(request) }
        let a = answers[request.question] ?? Answer(parts: ["The page doesn't seem to say."], quotes: [])
        let hangs = hang.contains(request.question), fails = failAfterFirst.contains(request.question), delay = self.delay
        return AsyncThrowingStream { c in
            Task.detached {
                if hangs {
                    let end = Date().addingTimeInterval(8)
                    while Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
                    return c.finish()
                }
                for (i, p) in a.parts.enumerated() {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
                    c.yield(AskPagePartial(answer: p, quotes: i == a.parts.count - 1 ? a.quotes : []))
                    if fails { return c.finish(throwing: CocoaError(.coderReadCorrupt)) }
                }
                c.finish()
            }
        }
    }
}

final class ScriptedSummaryModel: LinkPreviewModel, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [LinkSummaryRequest] = []
    var answers: [String: LinkSummary] = [:]
    var delay: TimeInterval = 0.3

    var asked: [LinkSummaryRequest] { lock.withLock { requests } }

    func summarize(_ request: LinkSummaryRequest) async throws -> LinkSummary {
        lock.withLock { requests.append(request) }
        try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
        return answers[request.title] ?? LinkSummary(summary: "A page called \(request.title). It has some text on it.", keyPoints: [])
    }
}

final class ScriptedFileNameModel: TidyDownloadModel, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [TidyDownloadRequest] = []
    var answers: [String: String] = [:]

    var asked: [TidyDownloadRequest] { lock.withLock { requests } }

    func fileName(for request: TidyDownloadRequest) async throws -> String {
        lock.withLock { requests.append(request) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        // By the start of the name: a browser may add " (1)" to a name that's taken.
        return answers.first { request.fileName.hasPrefix($0.key) }?.value ?? "Something made up entirely"
    }
}

extension SnapshotRunner {
    /// `capture`, then `views` drawn again over it at their place (the capture draws the page over everything that
    /// reaches into the page card; on screen the AI cards are above it).
    func captureAIOnTop(_ name: String, _ views: @escaping () -> [NSView]) {
        step { [self] done in
            captureNow(name) { [self] in
                defer { done() }
                let url = dir.appendingPathComponent(name + ".png"), size = c.root.bounds.size
                guard let base = NSImage(contentsOf: url),
                      let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
                rep.size = size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                base.draw(in: NSRect(origin: .zero, size: size))
                for v in views() where v.window === c.window && v.superview != nil {
                    guard let image = render(v) else { continue }
                    let f = c.root.convert(v.bounds, from: v)
                    image.draw(in: NSRect(x: f.minX, y: size.height - f.maxY, width: f.width, height: f.height))
                }
                NSGraphicsContext.restoreGraphicsState()
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
    }

    /// Where the run's window is while the owner may be at the Mac (these checks post no HID events and use no
    /// clipboard, so they run with the owner active): HID idle, the active Space, occlusion, the lock screen.
    var aiEnvironment: (line: String, blocked: String?) {
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
        let w = c.window
        let onSpace = w.isOnActiveSpace, visible = w.occlusionState.contains(.visible), locked = Self.screenLocked
        let blocked = locked ? "the screen is locked" : !onSpace ? "our window isn't on the active Space"
            : !visible ? "our window is covered by another window" : nil
        return ("HID idle \(Int(idle)) s, on the active Space \(onSpace), visible \(visible), screen locked \(locked)", blocked)
    }

    /// `check`, except that a failure while our window is covered, off the active Space or behind the lock screen is
    /// FAIL-ENV, with the evidence.
    func aiCheck(_ ok: Bool, _ what: String) {
        let env = aiEnvironment
        guard !ok, let why = env.blocked else { return check(ok, what) }
        note("FAIL-ENV " + what + " (\(why); \(env.line))")
    }

    /// The AI features' telemetry is closed: `feature.used` with one of their names and on, off or used, nothing else.
    func checkAIEvents(_ tag: String, _ events: [TelemetryEvent], expect: [String]) {
        let names: Set<String> = ["ai.ask_page", "ai.link_preview", "ai.tidy_downloads", "ai.tidy_titles"]
        var seen: [String] = []
        var closed = true
        for e in events {
            guard case let .featureUsed(f) = e else { closed = false; continue }
            let keys = Set(e.properties.keys)
            closed = closed && names.contains(f.name) && ["on", "off", "used"].contains(f.variant ?? "") && keys == ["feature", "variant"]
            seen.append(f.name + ":" + (f.variant ?? ""))
        }
        aiCheck(closed && expect.allSatisfy(seen.contains),
              "\(tag): telemetry only says which AI feature and on, off or used (\(seen.joined(separator: ", ")))")
    }
}
#endif

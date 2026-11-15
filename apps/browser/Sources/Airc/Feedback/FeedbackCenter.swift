// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Help › Send Feedback… (docs/user/feedback.md): where a message goes (aircbrowser.com's /api/feedback, the sharing
/// service's address, so test builds use AIRC_SHARING_BASE), the outbox that keeps it while Airc is offline, and the
/// two things the person may add: a picture of the Airc window they were in, and the app's details.
final class FeedbackCenter {
    static let shared = FeedbackCenter()

    var service: SharingService { serviceOverride ?? SharingCenter.shared.service }
    #if AIRC_TESTING
    /// Checks point it elsewhere for a while (a closed port: offline).
    var serviceOverride: SharingService?
    #else
    let serviceOverride: SharingService? = nil
    #endif
    let outbox = FeedbackOutbox(folder: AppPaths.dataDirectory.appendingPathComponent("Feedback Outbox", isDirectory: true))
    static let didChange = Notification.Name("AircFeedbackOutboxDidChange")

    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var flushing = false
    weak var app: AppDelegate?

    /// At launch: anything left in the outbox goes when the network is there, and again every few minutes until sent.
    func start(app: AppDelegate) {
        self.app = app
        guard !outbox.waiting().isEmpty else { return }
        watch()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.flush() }
    }

    var waitingCount: Int { outbox.waiting().count }

    /// Watches the network while something waits (NetworkWatch: the path coming back is a retry), and tries again every
    /// five minutes; stops once the outbox is empty.
    func watch() {
        if observer == nil {
            NetworkWatch.shared.start()
            observer = NotificationCenter.default.addObserver(forName: NetworkWatch.restored, object: nil, queue: .main) { [weak self] _ in
                self?.flush()
            }
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.flush() }
        }
    }

    private func stopWatching() {
        observer.map(NotificationCenter.default.removeObserver)
        observer = nil
        timer?.invalidate()
        timer = nil
    }

    /// Sends what's waiting, oldest first. A message sent later says so in the window in front.
    @discardableResult
    func flush() -> Task<Int, Never>? {
        guard !flushing, !outbox.waiting().isEmpty else {
            if outbox.waiting().isEmpty { stopWatching() }
            return nil
        }
        flushing = true
        let outbox = outbox, service = service
        return Task { @MainActor in
            let sent = await outbox.flush(with: service)
            flushing = false
            if outbox.waiting().isEmpty { stopWatching() }
            NotificationCenter.default.post(name: Self.didChange, object: self)
            if sent > 0, let c = app?.controller(for: NSApp.keyWindow) ?? app?.controller {
                c.showToast(sent == 1 ? "Your saved feedback was sent" : "Your \(sent) saved feedback messages were sent")
            }
            return sent
        }
    }

    /// Send: into the outbox first (so nothing is lost if Airc quits), then one try now.
    @MainActor
    func send(_ report: FeedbackReport) async -> FeedbackOutbox.Outcome {
        do {
            try outbox.add(report)
        } catch {
            return .refused("Airc couldn’t save your message: \(error.localizedDescription)")
        }
        let outcome = await outbox.attempt(report, with: service)
        if outcome == .kept { watch() }
        NotificationCenter.default.post(name: Self.didChange, object: self)
        return outcome
    }

    // MARK: What may be added

    /// "Include app info": the version and build, the engine, the macOS version, the Mac's model and the locale.
    static func appInfo(app: AppDelegate?) -> FeedbackReport.AppInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if canImport(AircCore)
        let engine = app?.options.engine == "chromium" ? "chromium" : "webkit"
        #else
        let engine = "webkit"
        #endif
        return FeedbackReport.AppInfo(version: info["CFBundleShortVersionString"] as? String ?? "",
                                      build: info["CFBundleVersion"] as? String ?? "", engine: engine,
                                      macOS: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
                                      model: hardwareModel(), locale: Locale.current.identifier)
    }

    /// "Mac16,1", "MacBookPro18,3".
    static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0, size < 256 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// A picture of this browser window as Airc draws it: its own views from their layers, and the pages on its card
    /// from the engines' own pictures (Capture's sources). Never a screen capture: no other app, no other window, no
    /// permission prompt. nil when there's nothing to picture.
    static func picture(of c: WindowController, _ done: @escaping (CGImage?) -> Void) {
        let root = c.captureRoot
        guard let base = CaptureSession.picture(of: root), root.bounds.width > 0 else { return done(nil) }
        let scale = CGFloat(base.width) / root.bounds.width
        /// A frame in the root view, in the picture's pixels (bottom-left origin).
        func pixels(_ f: CGRect) -> CGRect {
            let y = root.isFlipped ? root.bounds.height - f.maxY : f.minY
            return CGRect(x: f.minX * scale, y: y * scale, width: f.width * scale, height: f.height * scale)
        }
        let natives = c.captureViews.map { (frame: pixels($0.convert($0.bounds, to: root)), image: CaptureSession.picture(of: $0)) }
        let tabs = c.capturePages
        let frames = tabs.map { pixels($0.view.convert($0.view.bounds, to: root)) }
        var images = [CGImage?](repeating: nil, count: tabs.count)
        var left = tabs.count
        func compose() {
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return done(nil) }
            let all = CGRect(x: 0, y: 0, width: base.width, height: base.height)
            // An opaque picture: the window's background under its translucent parts.
            ctx.setFillColor(c.window.backgroundColor.usingColorSpace(.sRGB)?.cgColor ?? CGColor(gray: 0.95, alpha: 1))
            ctx.fill(all)
            ctx.interpolationQuality = .high
            // The root view is flipped: its layer tree renders top-down, so it's drawn mirrored back.
            if root.isFlipped {
                ctx.saveGState()
                ctx.translateBy(x: 0, y: all.height)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(base, in: all)
                ctx.restoreGState()
            } else {
                ctx.draw(base, in: all)
            }
            for n in natives { if let i = n.image { ctx.draw(i, in: n.frame) } }
            for (i, f) in frames.enumerated() { if let image = images[i] { ctx.draw(image, in: f) } }
            done(ctx.makeImage())
        }
        if tabs.isEmpty { return compose() }
        for (i, t) in tabs.enumerated() {
            CaptureSession.picture(of: t) { image in
                images[i] = image
                left -= 1
                if left == 0 { compose() }
            }
        }
    }

    /// The JPEG that's sent: at most 1920 pixels across, well under the service's 2 MB.
    static func jpeg(_ image: CGImage, longestSide: CGFloat = 1920, limit: Int = 1_500_000) -> Data? {
        var side = longestSide
        for quality in [0.8, 0.7, 0.6, 0.5] {
            let ratio = min(1, side / CGFloat(max(image.width, image.height)))
            let w = max(1, Int(CGFloat(image.width) * ratio)), h = max(1, Int(CGFloat(image.height) * ratio))
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let scaled = ctx.makeImage() else { return nil }
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return nil }
            if data.length <= limit { return data as Data }
            side *= 0.8
        }
        return nil
    }
}

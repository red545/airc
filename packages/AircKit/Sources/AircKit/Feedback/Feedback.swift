// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Help › Send Feedback… (docs/user/feedback.md, docs/dev/feedback-service.md): one message to aircbrowser.com's
/// POST /api/feedback, with only what the person typed and ticked. The service checks the same formats
/// (apps/marketing/api/_lib/feedback.js); anything else in a request refuses it whole.
public struct FeedbackReport: Codable, Equatable, Sendable {
    public static let maximumMessage = 5000
    public static let maximumEmail = 254
    /// The picture's own bytes. The app makes a JPEG well under this. (0.1.10–0.1.11's single screenshot, still read
    /// from an outbox they left.)
    public static let maximumScreenshot = 2 * 1024 * 1024
    /// Pictures per message (the window's, pasted, dropped or chosen ones).
    public static let maximumImages = 5
    /// A picture as sent: each goes in a request of its own, under the service's 4.5 MB cap.
    public static let maximumImage = 4 * 1024 * 1024

    /// The app details "Include app info" adds, each in a fixed format: never a URL, tab, history or profile.
    public struct AppInfo: Codable, Equatable, Sendable {
        public var version: String?
        public var build: String?
        public var engine: String?
        public var macOS: String?
        public var model: String?
        public var locale: String?

        /// Each value is checked against its format; anything else is left out.
        public init(version: String, build: String, engine: String, macOS: String, model: String, locale: String) {
            self.version = Self.matching(version, #"^[0-9]{1,4}(\.[0-9]{1,4}){0,3}$"#)
            self.build = Self.matching(build, #"^[0-9]{1,14}$|^dev$"#)
            self.engine = Self.matching(engine, #"^(chromium|webkit)$"#)
            self.macOS = Self.matching(macOS, #"^[0-9]{1,3}\.[0-9]{1,3}(\.[0-9]{1,3})?$"#)
            self.model = Self.matching(model, #"^[A-Za-z]{2,24}[0-9]{1,3},[0-9]{1,3}$"#)
            // "en_AT@calendar=gregorian" → "en_AT".
            let plain = locale.split(separator: "@").first.map(String.init) ?? ""
            self.locale = Self.matching(plain, #"^[A-Za-z]{2,3}([_-][A-Za-z0-9]{2,8}){0,2}$"#)
        }

        static func matching(_ s: String, _ pattern: String) -> String? {
            s.range(of: pattern, options: .regularExpression) != nil ? s : nil
        }

        /// The rows the sheet shows, in the order they're sent.
        public var rows: [(label: String, value: String)] {
            var r: [(String, String)] = []
            if let version { r.append(("Airc", version + (build.map { " (\($0))" } ?? ""))) }
            if let engine { r.append(("Engine", engine == "chromium" ? "Chromium" : "WebKit")) }
            if let macOS { r.append(("macOS", macOS)) }
            if let model { r.append(("Mac", model)) }
            if let locale { r.append(("Locale", locale)) }
            return r
        }
    }

    public struct Screenshot: Codable, Equatable, Sendable {
        public var type: String
        public var base64: String
        public init(jpeg: Data) {
            type = "image/jpeg"
            base64 = jpeg.base64EncodedString()
        }
        public var byteCount: Int { base64.utf8.count / 4 * 3 - base64.utf8.reversed().prefix(while: { $0 == UInt8(ascii: "=") }).count }
    }

    /// A picture, ready to send: PNG or JPEG without metadata (FeedbackImage.prepare). Kept whole in the outbox; the
    /// message lists it (type, size, SHA-256) and it follows in a request of its own.
    public struct Image: Codable, Equatable, Sendable {
        public var type: String
        public var base64: String
        public init(type: String, data: Data) {
            self.type = type
            base64 = data.base64EncodedString()
        }
        public var data: Data { Data(base64Encoded: base64) ?? Data() }
        var listing: [String: Any] {
            let d = data
            return ["type": type, "size": d.count, "sha256": SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()]
        }
    }

    public var version = 1
    public var message: String
    public var email: String?
    public var app: AppInfo?
    public var screenshot: Screenshot?
    /// nil when there are none (and in an outbox file from before pictures).
    public var images: [Image]?
    /// A random id for this message, so a resend after a lost answer stays one entry.
    public var client: String
    /// When it was written (a queued message is sent later).
    public var writtenAt: String

    public init(message: String, email: String?, app: AppInfo?, screenshot: Screenshot? = nil, images: [Image] = [],
                client: String = UUID().uuidString, writtenAt: Date = Date()) {
        self.message = message.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let e = email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.email = e.isEmpty ? nil : e
        self.app = app
        self.screenshot = screenshot
        self.images = images.isEmpty ? nil : images
        self.client = client
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        self.writtenAt = f.string(from: writtenAt)
    }

    /// Why it can't be sent yet, as a sentence for the sheet, or nil.
    public var problem: String? {
        if message.isEmpty { return "Write a message first." }
        if message.count > Self.maximumMessage { return "The message is longer than \(Self.maximumMessage) characters." }
        if Self.hidesText(message) { return "The message has hidden characters in it." }
        if let email, !Self.isEmail(email) { return "The reply address doesn’t look like an email address." }
        if let s = screenshot, s.byteCount > Self.maximumScreenshot { return "The screenshot is too large to send." }
        let pictures = images ?? []
        if pictures.count > Self.maximumImages { return "At most \(Self.maximumImages) pictures go with one message." }
        if pictures.contains(where: { !["image/png", "image/jpeg"].contains($0.type) }) { return "Pictures must be PNG or JPEG." }
        if pictures.contains(where: { $0.data.isEmpty || $0.data.count > Self.maximumImage }) { return "A picture is too large to send." }
        return nil
    }

    public static func isEmail(_ s: String) -> Bool {
        s.utf8.count <= maximumEmail && !hidesText(s)
            && s.range(of: #"^[^\s@<>"(),;:\\\[\]]+@[^\s@<>"(),;:\\\[\]]+\.[^\s@<>"(),;:\\\[\]]+$"#, options: .regularExpression) != nil
    }

    /// Control characters other than tab and line breaks, and bidirectional controls, as the service refuses them.
    static func hidesText(_ s: String) -> Bool {
        s.unicodeScalars.contains { u in
            let v = u.value
            if v == 0x09 || v == 0x0a || v == 0x0d { return false }
            return v <= 0x1f || (0x7f...0x9f).contains(v) || v == 0x061c || v == 0x200e || v == 0x200f
                || (0x202a...0x202e).contains(v) || (0x2066...0x2069).contains(v)
        }
    }

    /// The whole report, pictures included: the outbox's file.
    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }

    /// The message's request: everything but the pictures' bytes, which follow one by one (each listed here).
    public func requestBody() throws -> Data {
        var o = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as? [String: Any] ?? [:]
        o["images"] = nil
        if let pictures = images, !pictures.isEmpty { o["images"] = pictures.map(\.listing) }
        return try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
    }
}

/// A picture the person adds to their feedback (pasted, dropped, chosen, or the window's): a PNG, JPEG or HEIC of at
/// most 5 MB, turned into what's sent. It's redrawn upright from its pixels alone, so nothing else in the file goes:
/// no Exif, location, camera, XMP or text. A HEIC becomes a JPEG; a PNG stays PNG unless that's over the sent size.
public enum FeedbackImage {
    /// The largest file that can be added.
    public static let maximumFile = 5 * 1024 * 1024
    /// Longest side of what's sent: a Retina window's full width fits.
    public static let maximumSide = 4096
    public static let accepted: [UTType] = [.png, .jpeg, .heic]

    public enum Refusal: Error, Equatable {
        case tooLarge, notAPicture, unsupported
        public var sentence: String {
            switch self {
            case .tooLarge: "Pictures can be at most 5 MB."
            case .notAPicture: "This isn’t a picture Airc can read."
            case .unsupported: "Only PNG, JPEG and HEIC pictures can be added."
            }
        }
    }

    public struct Prepared: Equatable, Sendable {
        public var type: String
        public var data: Data
        public var width: Int
        public var height: Int
        public var image: FeedbackReport.Image { .init(type: type, data: data) }
        public init(type: String, data: Data, width: Int, height: Int) {
            self.type = type
            self.data = data
            self.width = width
            self.height = height
        }
    }

    /// `data` (a file's or the pasteboard's bytes) as it will be sent, or why it can't be.
    public static func prepare(_ data: Data) -> Result<Prepared, Refusal> {
        guard data.count <= maximumFile else { return .failure(.tooLarge) }
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let uti = CGImageSourceGetType(src).map({ UTType($0 as String) }) ?? nil else { return .failure(.notAPicture) }
        guard accepted.contains(where: { uti.conforms(to: $0) }) else { return .failure(.unsupported) }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard w > 0, h > 0 else { return .failure(.notAPicture) }
        // Upright (its orientation applied), at most `maximumSide`, from the pixels alone.
        func drawn(_ side: Int) -> CGImage? {
            CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        }
        var side = min(maximumSide, max(w, h))
        let png = uti.conforms(to: .png)
        for attempt in 0..<6 {
            guard let image = drawn(side) else { return .failure(.notAPicture) }
            // A PNG keeps its sharp edges (most are screenshots); past the sent size it goes as a JPEG.
            let asPNG = png && attempt == 0
            if let out = encode(image, type: asPNG ? .png : .jpeg), out.count <= FeedbackReport.maximumImage {
                return .success(Prepared(type: asPNG ? "image/png" : "image/jpeg", data: out, width: image.width, height: image.height))
            }
            // A PNG first tries JPEG at full size; after that, smaller.
            if attempt > 0 || !png { side = Int(Double(side) * 0.75) }
        }
        return .failure(.tooLarge)
    }

    /// `image` alone in a new file: no properties, so no metadata (ImageIO writes only what it's given).
    public static func encode(_ image: CGImage, type: UTType, quality: Double = 0.85) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: quality] : [:]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

extension SharingService {
    /// Sends `report`; the entry's id. A resend of the same report (its client id) answers with the same id.
    /// Pictures follow the message one by one (the ones the service says are missing, so a resend sends only what
    /// didn't arrive), then it's published.
    public func sendFeedback(_ report: FeedbackReport) async throws -> String {
        if let p = report.problem { throw Failure.refused(p) }
        let body = try report.requestBody()
        let data = try await send("POST", "api/feedback", body: body, expect: [200, 201], limit: 4096)
        struct Answer: Decodable { var id: String; var missing: [Int]? }
        guard let a = try? JSONDecoder().decode(Answer.self, from: data), HostedShareLink.isID(a.id) else { throw Failure.damaged }
        let pictures = report.images ?? []
        guard !pictures.isEmpty else { return a.id }
        let auth = ["Authorization": "Bearer \(report.client)"]
        for n in a.missing ?? Array(pictures.indices) {
            guard pictures.indices.contains(n) else { throw Failure.damaged }
            _ = try await send("PUT", "api/feedback", query: ["id": a.id, "image": String(n)], body: pictures[n].data, headers: auth,
                               contentType: pictures[n].type, expect: [204], limit: 4096)
        }
        do {
            _ = try await send("POST", "api/feedback", query: ["id": a.id, "publish": "1"], headers: auth, expect: [200], limit: 4096)
        } catch Failure.refused {
            // 409: a picture didn't arrive after all. Kept: the next try sends what's missing.
            throw Failure.unavailable
        }
        return a.id
    }
}

/// Feedback that couldn't be sent yet (offline, the service down or busy): one JSON file per message in a folder of
/// Airc's data, sent oldest first when the network is back. It holds only what the person chose to send.
public struct FeedbackOutbox: Sendable {
    public let folder: URL
    /// At most this many wait; the oldest goes first when another is added.
    public static let capacity = 20

    public init(folder: URL) { self.folder = folder }

    private func file(_ r: FeedbackReport) -> URL { folder.appendingPathComponent("\(r.client).json") }

    public func add(_ r: FeedbackReport) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try r.encoded().write(to: file(r), options: [.atomic])
        let all = waiting()
        if all.count > Self.capacity { all.prefix(all.count - Self.capacity).forEach(remove) }
    }

    public func remove(_ r: FeedbackReport) {
        try? FileManager.default.removeItem(at: file(r))
    }

    /// What's waiting, oldest first. A file that isn't a report is removed.
    public func waiting() -> [FeedbackReport] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var out: [FeedbackReport] = []
        for f in files where f.pathExtension == "json" {
            if let d = try? Data(contentsOf: f), let r = try? JSONDecoder().decode(FeedbackReport.self, from: d) { out.append(r) }
            else { try? FileManager.default.removeItem(at: f) }
        }
        return out.sorted { ($0.writtenAt, $0.client) < ($1.writtenAt, $1.client) }
    }

    public enum Outcome: Equatable, Sendable {
        case sent(id: String)
        /// Kept for later: offline, or the service down or limiting.
        case kept
        /// The service refused it for good (it's removed): the reason.
        case refused(String)
    }

    /// Tries one report: sent or refused ones leave the outbox; anything that may work later stays.
    public func attempt(_ r: FeedbackReport, with service: SharingService) async -> Outcome {
        do {
            let id = try await service.sendFeedback(r)
            remove(r)
            return .sent(id: id)
        } catch SharingService.Failure.refused(let why) {
            remove(r)
            return .refused(why)
        } catch {
            return .kept
        }
    }

    /// Sends everything waiting, oldest first; stops at the first one that has to wait. How many were sent.
    public func flush(with service: SharingService) async -> Int {
        var sent = 0
        for r in waiting() {
            switch await attempt(r, with: service) {
            case .sent: sent += 1
            case .refused: continue
            case .kept: return sent
            }
        }
        return sent
    }
}

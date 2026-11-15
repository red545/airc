// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AircKit

/// Help › Send Feedback…'s client (Feedback/Feedback.swift) against a stubbed network: what a report holds, the
/// request, the answers, and the outbox that keeps a message while offline. The service itself is tested in
/// apps/marketing/test/feedback.test.mjs.
final class FeedbackTests: XCTestCase {
    final class Stub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var answer: (URLRequest, Data?) -> (Int, Data) = { _, _ in (404, Data()) }
        nonisolated(unsafe) static var seen: [(URLRequest, Data?)] = []
        nonisolated(unsafe) static var offline = false
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            if Self.offline {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            var body = request.httpBody
            if body == nil, let s = request.httpBodyStream {
                s.open()
                var d = Data(), buf = [UInt8](repeating: 0, count: 65536)
                while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
                s.close()
                body = d
            }
            Self.seen.append((request, body))
            let (status, data) = Self.answer(request, body)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    var service: SharingService {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [Stub.self]
        return SharingService(base: URL(string: "http://127.0.0.1:4390")!, session: URLSession(configuration: c))
    }

    var folder: URL!
    override func setUp() {
        Stub.seen = []
        Stub.offline = false
        Stub.answer = { _, _ in (201, Data(#"{"id":"AbCdEfGhIjKl"}"#.utf8)) }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("feedback-tests-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    let app = FeedbackReport.AppInfo(version: "0.1.9", build: "202611120930", engine: "chromium", macOS: "26.6.2", model: "Mac16,1",
                                     locale: "en_AT@calendar=gregorian")

    func testAppInfoKeepsOnlyItsFormats() {
        XCTAssertEqual(app.locale, "en_AT")
        XCTAssertEqual(app.rows.map(\.label), ["Airc", "Engine", "macOS", "Mac", "Locale"])
        XCTAssertEqual(app.rows.first?.value, "0.1.9 (202611120930)")
        let odd = FeedbackReport.AppInfo(version: "0.1.9 https://x.example", build: "12; rm", engine: "gecko", macOS: "twenty-six",
                                         model: "/Users/someone", locale: "https://evil.example")
        XCTAssertNil(odd.version); XCTAssertNil(odd.build); XCTAssertNil(odd.engine)
        XCTAssertNil(odd.macOS); XCTAssertNil(odd.model); XCTAssertNil(odd.locale)
        XCTAssertTrue(odd.rows.isEmpty)
    }

    func testProblems() {
        XCTAssertEqual(FeedbackReport(message: "  \n ", email: nil, app: nil, screenshot: nil).problem, "Write a message first.")
        XCTAssertNotNil(FeedbackReport(message: String(repeating: "x", count: 5001), email: nil, app: nil, screenshot: nil).problem)
        XCTAssertNotNil(FeedbackReport(message: "a \u{202E} b", email: nil, app: nil, screenshot: nil).problem)
        XCTAssertNotNil(FeedbackReport(message: "hi", email: "nope", app: nil, screenshot: nil).problem)
        XCTAssertNil(FeedbackReport(message: "hi", email: "  ", app: nil, screenshot: nil).email)
        XCTAssertNil(FeedbackReport(message: "hi", email: "someone@example.com", app: app, screenshot: nil).problem)
    }

    func testTheRequestHoldsOnlyWhatWasChosen() async throws {
        let shot = FeedbackReport.Screenshot(jpeg: Data([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]))
        XCTAssertEqual(shot.byteCount, 7)
        let r = FeedbackReport(message: " It flickers.\r\n", email: "someone@example.com", app: app, screenshot: shot)
        let id = try await service.sendFeedback(r)
        XCTAssertEqual(id, "AbCdEfGhIjKl")
        let (req, body) = try XCTUnwrap(Stub.seen.first)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.absoluteString, "http://127.0.0.1:4390/api/feedback")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(body)) as? [String: Any])
        XCTAssertEqual(Set(o.keys), ["version", "message", "email", "app", "screenshot", "client", "writtenAt"])
        XCTAssertEqual(o["message"] as? String, "It flickers.")
        XCTAssertEqual(Set(((o["app"] as? [String: Any]) ?? [:]).keys), ["version", "build", "engine", "macOS", "model", "locale"])
        XCTAssertEqual((o["screenshot"] as? [String: Any])?["type"] as? String, "image/jpeg")

        // Nothing ticked: only the message, its id and time.
        Stub.seen = []
        _ = try await service.sendFeedback(FeedbackReport(message: "Hi", email: nil, app: nil, screenshot: nil))
        let bare = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(Stub.seen.first?.1)) as? [String: Any])
        XCTAssertEqual(Set(bare.keys), ["version", "message", "client", "writtenAt"])
    }

    func testAnswers() async {
        let r = FeedbackReport(message: "Hi", email: nil, app: nil, screenshot: nil)
        Stub.answer = { _, _ in (422, Data(#"{"error":"invalid","message":"Write a message first."}"#.utf8)) }
        do { _ = try await service.sendFeedback(r); XCTFail() } catch { XCTAssertEqual(error as? SharingService.Failure, .refused("Write a message first.")) }
        Stub.answer = { _, _ in (429, Data()) }
        do { _ = try await service.sendFeedback(r); XCTFail() } catch { XCTAssertEqual(error as? SharingService.Failure, .rateLimited) }
        Stub.answer = { _, _ in (201, Data(#"{"id":"../../etc"}"#.utf8)) }
        do { _ = try await service.sendFeedback(r); XCTFail() } catch { XCTAssertEqual(error as? SharingService.Failure, .damaged) }
        Stub.offline = true
        do { _ = try await service.sendFeedback(r); XCTFail() } catch { XCTAssertEqual(error as? SharingService.Failure, .offline) }
    }

    func testOutboxKeepsWhatCantBeSentAndSendsItLater() async throws {
        let box = FeedbackOutbox(folder: folder)
        let a = FeedbackReport(message: "first", email: nil, app: nil, screenshot: nil, writtenAt: Date(timeIntervalSince1970: 1_000))
        let b = FeedbackReport(message: "second", email: nil, app: app, screenshot: nil, writtenAt: Date(timeIntervalSince1970: 2_000))
        try box.add(b)
        try box.add(a)
        XCTAssertEqual(box.waiting().map(\.message), ["first", "second"])

        Stub.offline = true
        let kept = await box.attempt(a, with: service)
        XCTAssertEqual(kept, .kept)
        let none = await box.flush(with: service)
        XCTAssertEqual(none, 0)
        XCTAssertEqual(box.waiting().count, 2)

        Stub.offline = false
        let sent = await box.flush(with: service)
        XCTAssertEqual(sent, 2)
        XCTAssertTrue(box.waiting().isEmpty)
        // The same client ids went out, so a resend after a lost answer stays one entry.
        let clients = Stub.seen.compactMap { try? JSONSerialization.jsonObject(with: $0.1 ?? Data()) as? [String: Any] }.compactMap { $0["client"] as? String }
        XCTAssertEqual(clients, [a.client, b.client])
    }

    func testOutboxDropsWhatTheServiceRefusesAndCapsItsSize() async throws {
        let box = FeedbackOutbox(folder: folder)
        let r = FeedbackReport(message: "Hi", email: nil, app: nil, screenshot: nil)
        try box.add(r)
        Stub.answer = { _, _ in (422, Data(#"{"message":"The app detail “model” isn't in Airc's format."}"#.utf8)) }
        let refused = await box.attempt(r, with: service)
        XCTAssertEqual(refused, .refused("The app detail “model” isn't in Airc's format."))
        XCTAssertTrue(box.waiting().isEmpty)

        for i in 0..<(FeedbackOutbox.capacity + 3) {
            try box.add(FeedbackReport(message: "m\(i)", email: nil, app: nil, screenshot: nil, writtenAt: Date(timeIntervalSince1970: Double(i) * 10)))
        }
        XCTAssertEqual(box.waiting().count, FeedbackOutbox.capacity)
        XCTAssertEqual(box.waiting().first?.message, "m3")
        try Data("junk".utf8).write(to: folder.appendingPathComponent("junk.json"))
        XCTAssertEqual(box.waiting().count, FeedbackOutbox.capacity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("junk.json").path))
    }

    // MARK: feedback2: pictures

    /// A tiny picture of `type` (with `metadata` written into it, as a camera would).
    func picture(_ type: UTType, width: Int = 40, height: Int = 30, metadata: [CFString: Any] = [:]) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, metadata as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    func properties(_ d: Data) -> [CFString: Any] {
        let src = CGImageSourceCreateWithData(d as CFData, nil)!
        return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
    }

    let camera: [CFString: Any] = [
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.2082, kCGImagePropertyGPSLatitudeRef: "N",
                                        kCGImagePropertyGPSLongitude: 16.3738, kCGImagePropertyGPSLongitudeRef: "E"],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "at home", kCGImagePropertyExifLensModel: "Lens"],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Phone", kCGImagePropertyTIFFModel: "Model 9"],
        kCGImagePropertyOrientation: 6,   // turned: 40×30 pixels show as 30×40
    ]

    func testPreparedPicturesLoseTheirMetadataAndStandUpright() throws {
        let jpeg = picture(.jpeg, metadata: camera)
        XCTAssertNotNil(properties(jpeg)[kCGImagePropertyGPSDictionary])
        let p = try FeedbackImage.prepare(jpeg).get()
        XCTAssertEqual(p.type, "image/jpeg")
        XCTAssertEqual([p.width, p.height], [30, 40])
        let after = properties(p.data)
        XCTAssertNil(after[kCGImagePropertyGPSDictionary])
        XCTAssertNil(after[kCGImagePropertyTIFFDictionary])
        XCTAssertNil((after[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment])
        XCTAssertNil((after[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifLensModel])
        XCTAssertEqual(after[kCGImagePropertyOrientation] as? Int ?? 1, 1)
        for needle in ["Phone", "Model 9", "at home", "Lens"] {
            XCTAssertNil(p.data.range(of: Data(needle.utf8)), needle)
        }

        let png = try FeedbackImage.prepare(picture(.png, metadata: camera)).get()
        XCTAssertEqual(png.type, "image/png")
        XCTAssertNil(properties(png.data)[kCGImagePropertyGPSDictionary])

        let heic = picture(.heic, metadata: camera)
        let fromHEIC = try FeedbackImage.prepare(heic).get()
        XCTAssertEqual(fromHEIC.type, "image/jpeg")
        XCTAssertEqual(fromHEIC.data.prefix(3), Data([0xff, 0xd8, 0xff]))
        XCTAssertNil(properties(fromHEIC.data)[kCGImagePropertyGPSDictionary])
    }

    func testPicturesTheSheetRefuses() {
        XCTAssertEqual(FeedbackImage.prepare(Data("not a picture".utf8)), .failure(.notAPicture))
        XCTAssertEqual(FeedbackImage.prepare(picture(.gif)), .failure(.unsupported))
        XCTAssertEqual(FeedbackImage.prepare(picture(.tiff)), .failure(.unsupported))
        var big = picture(.png)
        big.append(Data(count: FeedbackImage.maximumFile))
        XCTAssertEqual(FeedbackImage.prepare(big), .failure(.tooLarge))
        let six = (0..<6).map { _ in FeedbackReport.Image(type: "image/png", data: Data([1])) }
        XCTAssertNotNil(FeedbackReport(message: "hi", email: nil, app: nil, images: six).problem)
        XCTAssertNotNil(FeedbackReport(message: "hi", email: nil, app: nil, images: [.init(type: "image/gif", data: Data([1]))]).problem)
        XCTAssertNotNil(FeedbackReport(message: "hi", email: nil, app: nil,
                                       images: [.init(type: "image/png", data: Data(count: FeedbackReport.maximumImage + 1))]).problem)
    }

    func testPicturesFollowTheMessageThenItsPublished() async throws {
        let a = try FeedbackImage.prepare(picture(.png)).get(), b = try FeedbackImage.prepare(picture(.jpeg)).get()
        let r = FeedbackReport(message: "Look", email: nil, app: nil, images: [a.image, b.image])
        Stub.answer = { req, _ in
            if req.httpMethod == "PUT" { return (204, Data()) }
            if req.url?.query?.contains("publish=1") == true { return (200, Data(#"{"id":"AbCdEfGhIjKl"}"#.utf8)) }
            return (201, Data(#"{"id":"AbCdEfGhIjKl","missing":[0,1]}"#.utf8))
        }
        let id = try await service.sendFeedback(r)
        XCTAssertEqual(id, "AbCdEfGhIjKl")
        XCTAssertEqual(Stub.seen.map { $0.0.httpMethod ?? "" }, ["POST", "PUT", "PUT", "POST"])
        let first = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(Stub.seen[0].1)) as? [String: Any])
        let listed = try XCTUnwrap(first["images"] as? [[String: Any]])
        XCTAssertEqual(listed.count, 2)
        XCTAssertEqual(Set(listed[0].keys), ["type", "size", "sha256"])
        XCTAssertEqual(listed[0]["size"] as? Int, a.data.count)
        // The message itself carries no picture bytes.
        XCTAssertLessThan(Stub.seen[0].1?.count ?? 0, 2000)
        XCTAssertEqual(Stub.seen[1].0.url?.query, "id=AbCdEfGhIjKl&image=0")
        XCTAssertEqual(Stub.seen[1].0.value(forHTTPHeaderField: "Content-Type"), "image/png")
        XCTAssertEqual(Stub.seen[1].0.value(forHTTPHeaderField: "Authorization"), "Bearer \(r.client)")
        XCTAssertEqual(Stub.seen[1].1, a.data)
        XCTAssertEqual(Stub.seen[2].0.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        XCTAssertEqual(Stub.seen[2].1, b.data)
        XCTAssertEqual(Stub.seen[3].0.url?.query, "id=AbCdEfGhIjKl&publish=1")

        // A resend: only what the service says is missing goes again.
        Stub.seen = []
        Stub.answer = { req, _ in
            if req.httpMethod == "PUT" { return (204, Data()) }
            if req.url?.query?.contains("publish=1") == true { return (200, Data(#"{"id":"AbCdEfGhIjKl"}"#.utf8)) }
            return (200, Data(#"{"id":"AbCdEfGhIjKl","duplicate":true,"missing":[1]}"#.utf8))
        }
        _ = try await service.sendFeedback(r)
        XCTAssertEqual(Stub.seen.map { $0.0.url?.query ?? "" }, ["", "id=AbCdEfGhIjKl&image=1", "id=AbCdEfGhIjKl&publish=1"])

        // A picture that didn't arrive after all (409 at publish): kept for later, not dropped.
        let box = FeedbackOutbox(folder: folder)
        try box.add(r)
        Stub.answer = { req, _ in
            if req.httpMethod == "PUT" { return (204, Data()) }
            if req.url?.query?.contains("publish=1") == true { return (409, Data(#"{"message":"Some pictures haven't arrived yet."}"#.utf8)) }
            return (201, Data(#"{"id":"AbCdEfGhIjKl","missing":[0,1]}"#.utf8))
        }
        let outcome = await box.attempt(r, with: service)
        XCTAssertEqual(outcome, .kept)
        XCTAssertEqual(box.waiting().first?.images?.count, 2)
    }

    func testAnOutboxFileFromBeforePicturesStillSends() async throws {
        let old = #"{"client":"6a1f0c3e-2b7d-4a8e-9c11-0f5e3d2a1b77","message":"old","screenshot":{"base64":"/9j/4AEC","type":"image/jpeg"},"version":1,"writtenAt":"2026-11-12T10:00:00Z"}"#
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(old.utf8).write(to: folder.appendingPathComponent("6a1f0c3e-2b7d-4a8e-9c11-0f5e3d2a1b77.json"))
        let box = FeedbackOutbox(folder: folder)
        XCTAssertEqual(box.waiting().map(\.message), ["old"])
        XCTAssertNil(box.waiting().first?.images)
        let sent = await box.flush(with: service)
        XCTAssertEqual(sent, 1)
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(Stub.seen.first?.1)) as? [String: Any])
        XCTAssertNotNil(o["screenshot"])
        XCTAssertNil(o["images"])
    }
}

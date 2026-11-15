// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// H01, H02, B03: the sharing service's client (Sharing/SharingService.swift) against a stubbed network: the requests
/// it makes, and every answer it refuses. The service itself is tested in apps/marketing/test/sharing.test.mjs.
final class SharingServiceTests: XCTestCase {
    override class func setUp() { super.setUp(); TestSuffixes.install() }

    final class Stub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var answer: (URLRequest, Data?) -> (Int, Data) = { _, _ in (404, Data()) }
        nonisolated(unsafe) static var seen: [(URLRequest, Data?)] = []
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
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
        return SharingService(base: URL(string: "https://aircbrowser.com")!, session: URLSession(configuration: c))
    }

    let folder = ShareSnapshot(.folder(name: "Reading", icon: nil, items: [
        .tab(ShareTab(url: "https://example.com/a", title: "A")),
        .folder(name: "Inner", items: [.tab(ShareTab(url: "https://example.org/b"))]),
    ]))

    override func setUp() { Stub.seen = [] }

    func json(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o) }

    // MARK: Links

    func testHostedLinks() {
        let id = "Ab3dEf6hIj9K"
        XCTAssertEqual(HostedShareLink.id(from: URL(string: "https://aircbrowser.com/s/\(id)")), id)
        XCTAssertEqual(HostedShareLink.id(from: URL(string: "https://www.aircbrowser.com/s/\(id)/")), id)
        XCTAssertEqual(HostedShareLink.id(from: URL(string: "airc://share/\(id)")), id)
        XCTAssertEqual(HostedShareLink.appURL(id: id)?.absoluteString, "airc://share/\(id)")
        let local = URL(string: "http://127.0.0.1:4390")!
        XCTAssertEqual(HostedShareLink.id(from: URL(string: "http://127.0.0.1:4390/s/\(id)"), service: local), id)
        for bad in ["http://aircbrowser.com/s/\(id)", "https://aircbrowser.com/s/\(id)x", "https://aircbrowser.com/s/short",
                    "https://evil.example/s/\(id)", "https://aircbrowser.com.evil.example/s/\(id)", "https://aircbrowser.com/x/\(id)",
                    "https://aircbrowser.com/s/\(id)?x=1", "https://aircbrowser.com/s#v1.AAAA", "airc://share#v1.AAAA",
                    "airc://other/\(id)", "https://user@aircbrowser.com/s/\(id)", "http://127.0.0.1:4391/s/\(id)", "https://aircbrowser.com/s/../\(id)"] {
            XCTAssertNil(HostedShareLink.id(from: URL(string: bad), service: local), bad)
        }
        XCTAssertFalse(ShareLink.isLink(URL(string: "https://aircbrowser.com/s/\(id)")), "hosted and fragment links don't overlap")
    }

    // MARK: Publish, read, revoke

    func testPublishSendsTheSnapshotAndReadsTheLink() async throws {
        Stub.answer = { _, _ in (201, self.json(["id": "Ab3dEf6hIj9K", "url": "https://aircbrowser.com/s/Ab3dEf6hIj9K", "token": String(repeating: "t", count: 43)])) }
        let p = try await service.publish(folder)
        XCTAssertEqual(p.id, "Ab3dEf6hIj9K")
        XCTAssertEqual(p.url.absoluteString, "https://aircbrowser.com/s/Ab3dEf6hIj9K")
        let (req, body) = try XCTUnwrap(Stub.seen.first)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.absoluteString, "https://aircbrowser.com/api/share")
        XCTAssertNil(req.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(try ShareLink.decode(try XCTUnwrap(body)), folder, "the body is exactly the snapshot")
    }

    func testPublishRefusesABoostAndBadAnswers() async throws {
        do { _ = try await service.publish(ShareSnapshot(.boost(BoostGallery.entries[0].file))); XCTFail() } catch SharingService.Failure.refused {}
        for bad: [String: Any] in [["id": "short", "url": "https://aircbrowser.com/s/short", "token": String(repeating: "t", count: 43)],
                                   ["id": "Ab3dEf6hIj9K", "url": "javascript:alert(1)", "token": String(repeating: "t", count: 43)],
                                   ["id": "Ab3dEf6hIj9K", "url": "https://aircbrowser.com/s/Ab3dEf6hIj9K", "token": "x"]] {
            Stub.answer = { _, _ in (201, self.json(bad)) }
            do { _ = try await service.publish(folder); XCTFail("\(bad)") } catch SharingService.Failure.damaged {}
        }
    }

    func testReadingASnapshotIsAsStrictAsAFragmentLink() async throws {
        let good = try JSONSerialization.jsonObject(with: ShareLink.encode(folder))
        Stub.answer = { _, _ in (200, self.json(["id": "Ab3dEf6hIj9K", "createdAt": "2026-11-09T22:00:00Z", "snapshot": good])) }
        let s = try await service.snapshot(id: "Ab3dEf6hIj9K")
        XCTAssertEqual(s, folder)
        XCTAssertEqual(Stub.seen.first?.0.url?.absoluteString, "https://aircbrowser.com/api/share?id=Ab3dEf6hIj9K")

        let hostile: [[String: Any]] = [
            ["kind": "folder", "name": "x", "items": [["type": "tab", "url": "javascript:alert(1)"]]],
            ["kind": "folder", "name": "x", "items": [["type": "tab", "url": "file:///etc/passwd"]]],
            ["kind": "folder", "name": "x", "items": [["type": "tab", "url": "https://example.com/", "extra": 1]]],
            ["kind": "boost", "boost": [:]],
        ]
        for h in hostile {
            Stub.answer = { _, _ in (200, self.json(["snapshot": h])) }
            do { _ = try await service.snapshot(id: "Ab3dEf6hIj9K"); XCTFail("\(h)") } catch {}
        }
        Stub.answer = { _, _ in (404, self.json(["error": "notFound", "message": "gone"])) }
        do { _ = try await service.snapshot(id: "Ab3dEf6hIj9K"); XCTFail() } catch SharingService.Failure.notFound {}
        do { _ = try await service.snapshot(id: "../../etc"); XCTFail() } catch SharingService.Failure.notFound {}
    }

    func testRevokeSendsTheTokenAndTreatsGoneAsDone() async throws {
        Stub.answer = { _, _ in (204, Data()) }
        try await service.revoke(id: "Ab3dEf6hIj9K", token: "secret-token-0123456789")
        let req = try XCTUnwrap(Stub.seen.first?.0)
        XCTAssertEqual(req.httpMethod, "DELETE")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token-0123456789")
        Stub.answer = { _, _ in (404, Data()) }
        try await service.revoke(id: "Ab3dEf6hIj9K", token: "secret-token-0123456789")
        Stub.answer = { _, _ in (403, self.json(["error": "forbidden", "message": "Only the copy of Airc that made this link can take it back."])) }
        do { try await service.revoke(id: "Ab3dEf6hIj9K", token: "wrong-token-0123456789"); XCTFail() }
        catch SharingService.Failure.refused(let why) { XCTAssertEqual(why, "Only the copy of Airc that made this link can take it back.") }
    }

    func testErrors() async throws {
        let cases: [(Int, Data, SharingService.Failure)] = [
            (429, Data(), .rateLimited),
            (503, Data(), .unavailable),
            (422, json(["message": "This link contains an address Airc doesn't open."]), .refused("This link contains an address Airc doesn't open.")),
            (422, json(["message": "two\nlines"]), .refused("aircbrowser.com refused it.")),
            (302, Data(), .damaged),
        ]
        for (status, data, expected) in cases {
            Stub.answer = { _, _ in (status, data) }
            do { _ = try await service.publish(folder); XCTFail() } catch let f as SharingService.Failure { XCTAssertEqual(f, expected, "\(status)") }
        }
    }

    // MARK: Gallery

    func testGalleryActionGetReviewUpdate() throws {
        let entry = try JSONDecoder().decode(SharingService.GalleryEntry.self, from: Data("""
            {"id":"Ab3dEf6hIj9K","fileID":"F1","name":"Calm","site":"example.com","code":false,"preview":false,"approvedAt":"x","revision":2}
            """.utf8))
        func installed(_ id: String, _ revision: Int, _ kind: BoostOrigin.Kind) -> Boost {
            var b = Boost(domain: "example.com")
            b.origin = BoostOrigin(id: id, revision: revision, kind: kind, digest: b.contentDigest)
            return b
        }
        XCTAssertEqual(entry.action(installed: nil), .get)
        XCTAssertEqual(entry.action(installed: installed("F1", 1, .installed)), .update, "a later revision of one installed")
        XCTAssertEqual(entry.action(installed: installed("F1", 2, .installed)), .review, "the same revision")
        XCTAssertEqual(entry.action(installed: installed("F1", 5, .installed)), .review, "an older revision")
        XCTAssertEqual(entry.action(installed: installed("F1", 1, .shared)), .review, "the person's own shared Boost")
        XCTAssertEqual(entry.action(installed: installed("F2", 1, .installed)), .review, "another file")
        var old = entry
        old.revision = nil
        XCTAssertEqual(old.action(installed: installed("F1", 1, .installed)), .review, "an entry listed without a revision")
        XCTAssertEqual(SharingService.GalleryAction.update.rawValue, "Update")
    }

    func testGalleryListFileSubmitReport() async throws {
        let file = BoostGallery.entries[0].file
        let published = try JSONEncoder.boosts.encode(file.withoutPreview)
        Stub.answer = { req, _ in
            let q = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            switch (req.httpMethod ?? "", q.first?.name) {
            case ("GET", nil):
                return (200, self.json(["boosts": [
                    ["id": "Ab3dEf6hIj9K", "fileID": file.id!, "name": file.name, "site": file.site, "author": "Airc", "about": NSNull(),
                     "code": false, "preview": false, "link": NSNull(), "approvedAt": "2026-11-09T22:00:00Z", "revision": 3],
                    ["id": "bad", "name": "x", "site": "x.com", "code": false, "preview": false, "approvedAt": ""],
                ]]))
            case ("GET", "id"): return (200, published)
            case ("POST", nil): return (202, self.json(["id": "Zz3dEf6hIj9K", "status": "pending", "message": "Sent."]))
            case ("POST", "report"): return (202, self.json(["status": "received"]))
            default: return (404, Data())
            }
        }
        let list = try await service.galleryEntries()
        XCTAssertEqual(list.map(\.id), ["Ab3dEf6hIj9K"], "an entry with a malformed id is dropped")
        XCTAssertEqual(list.first?.revision, 3)
        let got = try await service.galleryFile(id: "Ab3dEf6hIj9K")
        XCTAssertEqual(got.name, file.name)
        let message = try await service.submit(file)
        XCTAssertEqual(message, "Sent.")
        let sent = try XCTUnwrap(Stub.seen.last?.1)
        XCTAssertEqual(try BoostFile.decode(sent).id, file.id, "the submission is the Boost file itself")
        try await service.report(id: "Ab3dEf6hIj9K", reason: .harmful, note: "  hides prices  ")
        let report = try XCTUnwrap(Stub.seen.last)
        XCTAssertEqual(report.0.url?.absoluteString, "https://aircbrowser.com/api/boosts?report=Ab3dEf6hIj9K")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: try XCTUnwrap(report.1)) as? [String: String], ["reason": "harmful", "note": "hides prices"])
    }

    func testGalleryFileIsCheckedAsAFile() async throws {
        Stub.answer = { _, _ in (200, Data(#"{"version":2,"name":"x"}"#.utf8)) }
        do { _ = try await service.galleryFile(id: "Ab3dEf6hIj9K"); XCTFail() } catch SharingService.Failure.damaged {}
    }

    // MARK: Records

    func testRecordsRoundTrip() {
        let r = SharedLinkRecord(id: "Ab3dEf6hIj9K", url: URL(string: "https://aircbrowser.com/s/Ab3dEf6hIj9K")!, kind: .space,
                                 name: "Trip", sourceID: "S1", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(SharedLinkRecord.load(SharedLinkRecord.save([r])), [r])
        XCTAssertEqual(SharedLinkRecord.load(Data("garbage".utf8)), [])
        XCTAssertFalse(String(decoding: SharedLinkRecord.save([r]), as: UTF8.self).contains("token"), "no token on disk")
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

final class LibraryMediaTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func file(_ name: String, _ minutes: Double, mime: String? = nil, source: LibraryFile.Source = .download,
                      complete: Bool = true, isPrivate: Bool = false, path: String? = nil) -> LibraryFile {
        LibraryFile(id: "p/\(name)/\(minutes)", path: path ?? "/scratch/\(name)", name: name, date: t0.addingTimeInterval(minutes * 60),
                    source: source, mimeType: mime, isComplete: complete, isPrivate: isPrivate)
    }

    func testKindsByTypeExtensionFirstThenMIME() {
        XCTAssertEqual(LibraryMedia.kind(name: "photo.JPG", mimeType: nil), .image)
        XCTAssertEqual(LibraryMedia.kind(name: "shot.png", mimeType: "application/octet-stream"), .image)
        XCTAssertEqual(LibraryMedia.kind(name: "logo.svg", mimeType: nil), .image)
        XCTAssertEqual(LibraryMedia.kind(name: "anim.gif", mimeType: nil), .image)
        XCTAssertEqual(LibraryMedia.kind(name: "clip.mov", mimeType: nil), .video)
        XCTAssertEqual(LibraryMedia.kind(name: "clip.mp4", mimeType: nil), .video)
        XCTAssertEqual(LibraryMedia.kind(name: "clip.m4v", mimeType: nil), .video)
        // Not media: documents, audio, archives; a known extension beats the server's MIME type.
        XCTAssertEqual(LibraryMedia.kind(name: "paper.pdf", mimeType: nil), .other)
        XCTAssertEqual(LibraryMedia.kind(name: "paper.pdf", mimeType: "image/png"), .other)
        XCTAssertEqual(LibraryMedia.kind(name: "song.mp3", mimeType: "audio/mpeg"), .other)
        XCTAssertEqual(LibraryMedia.kind(name: "notes.zip", mimeType: nil), .other)
        // No or an unknown extension: the MIME type, parameters ignored.
        XCTAssertEqual(LibraryMedia.kind(name: "download", mimeType: "image/webp"), .image)
        XCTAssertEqual(LibraryMedia.kind(name: "stream.xyzzy", mimeType: "video/mp4; codecs=avc1"), .video)
        XCTAssertEqual(LibraryMedia.kind(name: "download", mimeType: "text/html"), .other)
        XCTAssertEqual(LibraryMedia.kind(name: "download", mimeType: nil), .other)
    }

    func testMediaKeepsFinishedImagesAndVideosNewestFirst() {
        let files = [
            file("old.png", 1), file("doc.pdf", 5), file("film.mp4", 3), file("song.mp3", 4),
            file("partial.jpg", 6, complete: false), file("new.jpg", 7),
            file("Capture example.com.png", 2, mime: "image/png", source: .capture),
        ]
        let media = LibraryMedia.media(files) { _ in true }
        XCTAssertEqual(media.map(\.name), ["new.jpg", "film.mp4", "Capture example.com.png", "old.png"])
        XCTAssertEqual(media.map(\.kind), [.image, .video, .image, .image])
    }

    func testMissingFilesDropOut() {
        let files = [file("a.png", 1), file("b.png", 2), file("c.mov", 3)]
        let gone: Set<String> = ["/scratch/b.png"]
        XCTAssertEqual(LibraryMedia.media(files) { !gone.contains($0) }.map(\.name), ["c.mov", "a.png"])
        XCTAssertEqual(LibraryMedia.recent(files) { !gone.contains($0) }.map(\.name), ["c.mov", "a.png"])
        XCTAssertTrue(LibraryMedia.media(files) { _ in false }.isEmpty)
    }

    func testPrivateFilesNeverListed() {
        let files = [file("mine.png", 1), file("secret.png", 2, isPrivate: true), file("secret.pdf", 3, isPrivate: true)]
        XCTAssertEqual(LibraryMedia.media(files) { _ in true }.map(\.name), ["mine.png"])
        XCTAssertEqual(LibraryMedia.recent(files) { _ in true }.map(\.name), ["mine.png"])
    }

    func testRecentListsAnyTypeFiveNewestAndOnePerFile() {
        var files = (0..<8).map { file("f\($0).\($0 % 2 == 0 ? "pdf" : "png")", Double($0)) }
        // The same file downloaded again (Chromium's list keeps both rows): once, at its newest.
        files.append(file("f2.pdf", 20, path: "/scratch/f2.pdf"))
        files.append(file("empty", 30, path: ""))
        let recent = LibraryMedia.recent(files) { _ in true }
        XCTAssertEqual(recent.map(\.name), ["f2.pdf", "f7.png", "f6.pdf", "f5.png", "f4.pdf"])
        XCTAssertEqual(recent.first?.date, t0.addingTimeInterval(20 * 60))
        XCTAssertEqual(LibraryMedia.recent(files, limit: 2) { _ in true }.count, 2)
    }

    func testCaptureRecordsAddReplacePruneAndRoundTrip() throws {
        var r = CaptureRecords()
        r.add(path: "/scratch/one.png", date: t0)
        r.add(path: "/scratch/two.png", date: t0.addingTimeInterval(60))
        r.add(path: "/scratch/one.png", date: t0.addingTimeInterval(120))
        XCTAssertEqual(r.entries.map(\.path), ["/scratch/two.png", "/scratch/one.png"])
        XCTAssertEqual(r.files.map(\.source), [.capture, .capture])
        XCTAssertEqual(r.files.map(\.kind), [.image, .image])
        let decoded = try JSONDecoder().decode(CaptureRecords.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(decoded, r)
        XCTAssertFalse(r.prune { _ in true })
        XCTAssertTrue(r.prune { $0 != "/scratch/two.png" })
        XCTAssertEqual(r.entries.map(\.path), ["/scratch/one.png"])
        for i in 0..<(CaptureRecords.limit + 5) { r.add(path: "/scratch/\(i).png", date: t0) }
        XCTAssertEqual(r.entries.count, CaptureRecords.limit)
        XCTAssertEqual(r.entries.last?.path, "/scratch/\(CaptureRecords.limit + 4).png")
    }
}

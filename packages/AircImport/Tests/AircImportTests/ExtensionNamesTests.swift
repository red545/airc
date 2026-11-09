// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircImport

final class ExtensionNamesTests: XCTestCase {
    func testLocalePriorityFallbacksAndReadBoundary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = String(repeating: "a", count: 32)
        let path = "Extensions/\(id)/1_0/"
        func write(_ name: String, _ text: String) throws {
            let file = root.appendingPathComponent(path + name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        try write("manifest.json", #"{"name":"__MSG_title__","default_locale":"de"}"#)
        try write("_locales/fr/messages.json", #"{"TITLE":{"message":"Lecteur"}}"#)
        try write("_locales/de/messages.json", #"{"title":{"message":"Leser"}}"#)
        try write("_locales/en/messages.json", #"{"title":{"message":"Reader"}}"#)
        // An unreadable executable is deliberately not needed by the name reader.
        try write("background.js", "never read")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.appendingPathComponent(path + "background.js").path)
        let entry: [String: Any] = ["path": id + "/1_0"]
        func resolve(_ languages: [String]) -> String? {
            ExtensionNames.resolve(id: id, entry: entry, profile: root, tempRoot: root, languages: languages)
        }
        XCTAssertEqual(resolve(["fr-CA"]), "Lecteur")
        XCTAssertEqual(resolve(["it"]), "Leser")
        try write("_locales/de/messages.json", "broken")
        XCTAssertEqual(resolve(["it"]), "Reader")
        try write("_locales/fr/messages.json", String(repeating: "x", count: ExtensionNames.maxBytes + 1))
        XCTAssertEqual(resolve(["fr"]), "Reader")
        try write("manifest.json", String(repeating: "x", count: ExtensionNames.maxBytes + 1))
        XCTAssertNil(resolve(["en"]))
        try write("manifest.json", #"{"name":"__MSG_missing__","default_locale":"../../outside"}"#)
        XCTAssertNil(resolve(["../../outside"]))
        XCTAssertNil(ExtensionNames.resolve(id: id, entry: ["path": "../../outside"], profile: root, tempRoot: root))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("AircImport-") })
    }

    func testSymlinkedMetadataAndDirectoriesAreNotFollowed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = String(repeating: "b", count: 32)
        let folder = root.appendingPathComponent("Extensions/\(id)/1_0")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.json")
        try Data(#"{"name":"Outside"}"#.utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("manifest.json"), withDestinationURL: outside)
        XCTAssertNil(ExtensionNames.resolve(id: id, entry: ["path": id + "/1_0"], profile: root, tempRoot: root))
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: root)
        XCTAssertNil(ExtensionNames.resolve(id: id, entry: ["path": id + "/1_0"], profile: root, tempRoot: root))
        XCTAssertEqual(try Data(contentsOf: outside), Data(#"{"name":"Outside"}"#.utf8))
    }
}

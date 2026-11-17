// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

final class UpdateWarmupTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("updatewarm-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    @discardableResult
    private func stage(_ outer: String, _ inner: String, name: String = "Airc.app", id: String = "com.aircbrowser.Airc",
                       version: String, exe: String = "Airc", modified: Date = Date()) throws -> URL {
        let app = root.appendingPathComponent("\(outer)/\(inner)/\(name)", isDirectory: true)
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": id, "CFBundleVersion": version, "CFBundleExecutable": exe]
        try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let bin = app.appendingPathComponent("Contents/MacOS/\(exe)")
        fm.createFile(atPath: bin.path, contents: Data([0xCF, 0xFA]), attributes: [.posixPermissions: 0o755])
        try fm.setAttributes([.modificationDate: modified], ofItemAtPath: app.path)
        return app
    }

    func testInstallationDirectoryMatchesSparkle() {
        let caches = URL(fileURLWithPath: "/Users/x/Library/Caches")
        XCTAssertEqual(UpdateWarmup.installationDirectory(caches: caches, bundleIdentifier: "com.aircbrowser.Airc").path,
                       "/Users/x/Library/Caches/com.aircbrowser.Airc/org.sparkle-project.Sparkle/Installation")
        XCTAssertEqual(UpdateWarmup.installationDirectory(caches: caches, bundleIdentifier: "org.example.Thing.app").path,
                       "/Users/x/Library/Caches/org.example.Thing.app.sparkle/org.sparkle-project.Sparkle/Installation")
    }

    func testPicksNewestMatchingVersionAndIdentifier() throws {
        try stage("a", "1", version: "202611170628", modified: Date(timeIntervalSinceNow: -3600))
        let newest = try stage("b", "2", version: "202611170628")
        try stage("c", "3", version: "202611160000")                                // older build
        try stage("d", "4", id: "org.airc.Airc.dev", version: "202611170628")       // another app
        let found = UpdateWarmup.stagedBundle(in: [root], bundleIdentifier: "com.aircbrowser.Airc", version: "202611170628")
        XCTAssertEqual(found?.standardizedFileURL.path, newest.standardizedFileURL.path)
        XCTAssertNil(UpdateWarmup.stagedBundle(in: [root], bundleIdentifier: "com.aircbrowser.Airc", version: "1"))
        XCTAssertNil(UpdateWarmup.stagedBundle(in: [root.appendingPathComponent("missing")],
                                               bundleIdentifier: "com.aircbrowser.Airc", version: "202611170628"))
    }

    func testIgnoresSymbolicLinks() throws {
        let real = try stage("a", "1", version: "7")
        try fm.createDirectory(at: root.appendingPathComponent("b/2"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appendingPathComponent("b/2/Link.app"), withDestinationURL: real)
        try fm.createSymbolicLink(at: root.appendingPathComponent("c"), withDestinationURL: root.appendingPathComponent("a"))
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: real.path)
        let found = UpdateWarmup.stagedBundle(in: [root], bundleIdentifier: "com.aircbrowser.Airc", version: "7")
        XCTAssertEqual(found?.standardizedFileURL.path, real.standardizedFileURL.path)
    }

    func testMainExecutableMustBeARegularExecutableInsideMacOS() throws {
        let good = try stage("a", "1", version: "7")
        XCTAssertEqual(UpdateWarmup.mainExecutable(of: good)?.lastPathComponent, "Airc")
        let escape = try stage("b", "2", version: "7", exe: "../../../../x")
        XCTAssertNil(UpdateWarmup.mainExecutable(of: escape))
        let link = try stage("c", "3", version: "7")
        let bin = link.appendingPathComponent("Contents/MacOS/Airc")
        try fm.removeItem(at: bin)
        try fm.createSymbolicLink(at: bin, withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
        XCTAssertNil(UpdateWarmup.mainExecutable(of: link))
    }

    func testProbeArgumentsAreTheCheckChildWithAnImpossiblePath() {
        XCTAssertEqual(UpdateWarmup.probeArguments.count, 2)
        XCTAssertEqual(UpdateWarmup.probeArguments[0], "--airc-check-blocking-rules")
        XCTAssertTrue(UpdateWarmup.probeArguments[1].hasPrefix("/dev/null/"))
    }
}

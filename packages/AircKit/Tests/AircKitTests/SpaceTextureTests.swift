// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// arctextures (TH-4): a Space's texture (Arc's `modifiers.overlay`) is optional in every stored and synced theme.
/// Themes from before it read as grain; a texture a newer Airc writes reads, draws as grain and is kept and sent back
/// unchanged. Synthetic data only.
final class SpaceTextureTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("airc-arctextures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func json(_ theme: SpaceTheme) throws -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return String(decoding: try e.encode(theme), as: UTF8.self)
    }

    private func theme(_ s: String) throws -> SpaceTheme { try JSONDecoder().decode(SpaceTheme.self, from: Data(s.utf8)) }

    /// A theme as every build before arctextures wrote it (no texture key).
    private let oldTheme = #"{"appearance":"auto","colors":[{"a":1,"b":0.5,"g":0.25,"r":0.125}],"grain":0.3,"intensity":0.81}"#

    // MARK: Decoding and encoding

    func testAThemeFromBeforeTexturesReadsAsGrainAndEncodesByteForByte() throws {
        let t = try theme(oldTheme)
        XCTAssertEqual(t.texture, .grain)
        XCTAssertEqual(t.grain, 0.3)
        XCTAssertEqual(try json(t), oldTheme, "a grain theme must encode exactly as before (no churn in rows, sync, backups)")
    }

    func testEveryTextureRoundTrips() throws {
        XCTAssertEqual(SpaceTexture.allCases.map(\.rawValue), ["grain", "sand", "denim", "tweed"])
        for texture in SpaceTexture.allCases {
            let t = SpaceTheme(colors: [RGBA(0.2, 0.4, 0.6)], grain: 0.5, texture: texture)
            let s = try json(t)
            XCTAssertEqual(s.contains("\"texture\""), texture != .grain, s)
            let back = try theme(s)
            XCTAssertEqual(back, t)
            XCTAssertEqual(back.texture.effective, texture)
            XCTAssertTrue(back.texture.isKnown)
        }
    }

    func testAnUnknownTextureReadsDrawsAsGrainAndEncodesUnchanged() throws {
        let future = oldTheme.replacingOccurrences(of: #""intensity":0.81}"#, with: #""intensity":0.81,"texture":"velvet"}"#)
        let t = try theme(future)
        XCTAssertEqual(t.texture.rawValue, "velvet")
        XCTAssertFalse(t.texture.isKnown)
        XCTAssertEqual(t.texture.effective, .grain)
        XCTAssertEqual(try json(t), future, "this build sends back exactly what a newer one wrote")
    }

    func testANonStringTextureReadsAsGrainWithoutLosingTheSpace() throws {
        for value in [#"{"velvet":{}}"#, "7", "null", "[]"] {
            let s = oldTheme.replacingOccurrences(of: #""intensity":0.81}"#, with: #""intensity":0.81,"texture":\#(value)}"#)
            let t = try theme(s)
            XCTAssertEqual(t.texture, .grain, value)
            XCTAssertEqual(t.colors.count, 1, value)
        }
    }

    func testTheOtherKeysStillDecodeAsBefore() throws {
        // A theme missing a key it always had still fails, as the synthesized decoder did (no silent defaults).
        XCTAssertThrowsError(try theme(#"{"appearance":"auto","colors":[],"intensity":0.81}"#))
        // Values aren't clamped on decode, as before.
        XCTAssertEqual(try theme(#"{"appearance":"dark","colors":[],"grain":1.5,"intensity":0.81,"texture":"sand"}"#).grain, 1.5)
    }

    // MARK: Store, backup, sync

    func testTheStoreKeepsATextureAndANewerOneThroughWritesAndRelaunch() throws {
        let path = dir.appendingPathComponent("spaces.sqlite").path
        var sand = "", future = ""
        do {
            let s = try SpacesStore(path: path)
            sand = try s.createSpace(name: "Sand", theme: SpaceTheme(colors: [RGBA(0.9, 0.8, 0.7)], grain: 0.6, texture: .sand)).id
            future = try s.createSpace(name: "Future", theme: SpaceTheme(colors: [RGBA(0.1, 0.2, 0.3)], grain: 0.4,
                                                                          texture: SpaceTexture(rawValue: "velvet"))).id
            try s.flush()
        }
        do {
            let s = try SpacesStore(path: path)
            XCTAssertEqual(s.space(sand)?.theme.texture, .sand)
            XCTAssertEqual(s.space(future)?.theme.texture.rawValue, "velvet")
            try s.updateSpace(future) { $0.name = "Future 2" }  // an unrelated write
            try s.flush()
        }
        let s = try SpacesStore(path: path)
        XCTAssertEqual(s.space(future)?.name, "Future 2")
        XCTAssertEqual(s.space(future)?.theme.texture.rawValue, "velvet")
        XCTAssertEqual(s.space(sand)?.theme.texture, .sand)
    }

    func testBackupRoundTripKeepsEveryTexture() throws {
        let s = try makeStore()
        var ids: [String: String] = [:]
        for raw in ["grain", "sand", "denim", "tweed", "velvet"] {
            ids[raw] = try s.createSpace(name: raw, theme: SpaceTheme(colors: [RGBA(0.5, 0.5, 0.5)], grain: 0.5,
                                                                       texture: SpaceTexture(rawValue: raw))).id
        }
        let bytes = try s.exportJSON()
        let restored = try SpacesStore.readBackup(bytes).state
        for (raw, id) in ids {
            XCTAssertEqual(restored.spaces[id]?.theme.texture.rawValue, raw)
        }
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("velvet"))
        // A backup made before textures (no texture key anywhere) restores every Space as grain.
        func strip(_ v: Any) -> Any {
            if var o = v as? [String: Any] {
                o["texture"] = nil
                for (k, x) in o { o[k] = strip(x) }
                return o
            }
            if let a = v as? [Any] { return a.map(strip) }
            return v
        }
        let stripped = try JSONSerialization.data(withJSONObject: strip(JSONSerialization.jsonObject(with: bytes)))
        XCTAssertFalse(String(decoding: stripped, as: UTF8.self).contains("\"texture\""))
        let old = try SpacesStore.readBackup(stripped).state
        XCTAssertEqual(Set(ids.values.compactMap { old.spaces[$0]?.theme.texture }), [.grain])
    }

    /// Another Mac sets sand on one Space and a newer build's texture on another (theme records over the JSON wire); this
    /// Mac applies both, keeps the unknown one as it came, and sends nothing back for either.
    func testOverSyncTexturesArriveAndThisBuildSendsNothingBack() throws {
        let s = try makeStore()
        var adapter = SyncStoreAdapter(), replica = SyncReplica()
        let sand = try s.createSpace(name: "Sand", theme: SpaceTheme(colors: [RGBA(0.9, 0.8, 0.7)], grain: 0.6)).id
        let future = try s.createSpace(name: "Future", theme: SpaceTheme(colors: [RGBA(0.1, 0.2, 0.3)], grain: 0.4)).id
        try adapter.capture(s.state, into: &replica, now: 1)
        // The other Mac: the same records, then its edits.
        var other = SyncReplica()
        try other.receive(replica.log, now: 1)
        let ops = [
            try other.edit(SyncRecordID(.space, sand), [.theme: .theme(SpaceTheme(colors: [RGBA(0.9, 0.8, 0.7)], grain: 0.6, texture: .sand))], now: 5),
            try other.edit(SyncRecordID(.space, future), [.theme: .theme(SpaceTheme(colors: [RGBA(0.1, 0.2, 0.3)], grain: 0.4,
                                                                                   texture: SpaceTexture(rawValue: "velvet")))], now: 5),
        ]
        let bytes = try JSONEncoder().encode(ops)
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("velvet"))
        try replica.receive(try JSONDecoder().decode([SyncOperation].self, from: bytes), now: 6)
        _ = try s.applySync(replica, adapter: &adapter)
        adapter.rebase(s.state)   // as SyncEngine does right after applying
        XCTAssertEqual(s.space(sand)?.theme.texture, .sand)
        XCTAssertEqual(s.space(future)?.theme.texture.rawValue, "velvet")
        XCTAssertEqual(s.space(future)?.theme.texture.effective, .grain)
        let echo = try adapter.capture(s.state, into: &replica, now: 7)
        // (Applying may renumber Space order; only a theme sent back would be an echo.)
        XCTAssertTrue(echo.filter { $0.fields[.theme] != nil }.isEmpty, "this Mac must not send the themes back: \(echo)")
    }
}

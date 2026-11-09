// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// The real-iCloud test (docs/sync.md, "The real iCloud test"): a Developer ID-signed test build with the provisioning
/// profile, two installations (data folders) on one Mac and Apple Account, the real CloudKit container (Production),
/// in a zone of the test's own (`--sync-cloudkit-test-zone AircSidebarTest…`). Its group key is a local,
/// not-synchronizable item under a keychain service of its own, in the profile's access group: nothing reaches the
/// owner's other devices. Not in the suite: it needs the profile and the deployed schema.
///
/// - `icloudsync-real-a`: the first installation uploads a test Space.
/// - `icloudsync-real-b`: the second finds it (the key is already in this Mac's keychain), merges, edits.
/// - `icloudsync-real-cleanup`: the first gets the edits, then the test zone (all its records and its subscription)
///   and the test key are deleted, whatever happened before.
extension SnapshotRunner {
    func iCloudRealScenario() {
        let sync = SyncCenter.shared
        func waitFor(_ what: String, timeout: Double = 90, _ condition: @escaping () -> Bool) {
            step { [self] done in
                waitUntil(condition, timeout: timeout) { [self] in
                    if !condition() { note("FAIL \(script): timed out waiting for \(what) (status \(sync.status))") }
                    done()
                }
            }
        }
        func spaceNamed(_ name: String) -> Space? { c.store.orderedSpaces.first { $0.name == name } }
        func pinned(_ url: String, in space: Space?) -> Bool {
            c.store.state.items.values.contains { $0.savedURL == url && $0.spaceID == space?.id }
        }
        run { [self] in
            check(sync.backend == .cloudKit(container: "iCloud.com.aircbrowser.Airc") && sync.cloudTestZone?.hasPrefix("AircSidebarTest") == true,
                  "\(script): the real CloudKit container, in the test zone \(sync.cloudTestZone ?? "none") (backend \(sync.backend))")
        }
        switch script {
        case "icloudsync-real-a":
            run { [self] in
                check(sync.cloudDatabasesMade == 0 && !sync.isScheduling && !sync.hasTransport,
                      "icloudsync-real-a: with the entitlement and sync off, no CloudKit container, transport, timer or push registration")
                do {
                    let s = try c.store.createSpace(name: "iCloud test A", icon: .emoji("🧪"))
                    try pin("https://example.com/icloud-test-a", title: "Test A", icon: nil, space: s.id)
                } catch { note("FAIL \(script): seeding: \(error)") }
                sync.setEnabled(true)
            }
            waitFor("the first upload") { sync.status == .upToDate }
            run { [self] in
                check(sync.status == .upToDate && sync.devices.contains { $0.isThisMac },
                      "icloudsync-real-a: made the group, saved its key to the keychain (local test item) and uploaded (\(sync.devices.count) device)")
            }
        case "icloudsync-real-b":
            run { sync.setEnabled(true) }
            waitFor("the first-sync screen") { sync.firstSync != nil }
            run { [self] in
                check(sync.firstSync?.iCloud.spaces.contains("iCloud test A") == true,
                      "icloudsync-real-b: found the other installation's group and key, and its Space (\(sync.firstSync?.iCloud.spaces ?? []))")
                sync.choose(.merge, profiles: [:])
            }
            waitFor("the merge") { sync.status == .upToDate }
            var sent = false
            run { [self] in
                let space = spaceNamed("iCloud test A")
                check(space != nil && pinned("https://example.com/icloud-test-a", in: space),
                      "icloudsync-real-b: the Space and its pinned tab came through CloudKit")
                if let space {
                    try? c.store.updateSpace(space.id) { $0.name = "iCloud test A (from B)" }
                    try? pin("https://example.com/icloud-test-b", title: "Test B", icon: nil, space: space.id)
                }
                sync.syncNow { sent = true }
            }
            waitFor("the edits to go up") { sent && sync.status == .upToDate }
            run { [self] in check(sync.status == .upToDate, "icloudsync-real-b: a rename and a pinned tab went up") }
        case "icloudsync-real-cleanup":
            waitFor("the other installation's edits", timeout: 60) { spaceNamed("iCloud test A (from B)") != nil }
            run { [self] in
                let space = spaceNamed("iCloud test A (from B)")
                check(space != nil && pinned("https://example.com/icloud-test-b", in: space) && sync.devices.count == 2,
                      "icloudsync-real-cleanup: the other installation's rename and pinned tab arrived; \(sync.devices.count) devices")
                sync.setEnabled(false)
                check(!sync.isScheduling && !sync.hasTransport && sync.cloudDatabase == nil,
                      "icloudsync-real-cleanup: off removes the transport, its CloudKit container, the timer and the push registration")
            }
            var cleaned = false
            run { [self] in
                guard let container = SyncCapability.container, let zone = sync.cloudTestZone, let keys = sync.keyStore else {
                    note("FAIL icloudsync-real-cleanup: nothing to clean up with"); cleaned = true; return
                }
                let database = CloudKitSyncDatabase(container: container)
                Task { @MainActor in
                    let transport = CloudKitSyncTransport(database: database, device: UUID(), zone: zone, backoff: [1, 4])
                    var group: UUID?
                    do { group = try await transport.group()?.group } catch { note("cleanup: reading the group: \(error)") }
                    if let group { do { try keys.removeUnused(group: group) } catch { note("FAIL cleanup: the test key: \(error)") } }
                    do { try await database.deleteTestZone(zone, subscription: SyncCenter.testSubscription) }
                    catch { note("FAIL cleanup: deleting the test zone: \(error)") }
                    let keyGone = group.map { (try? keys.key(group: $0)) == nil } ?? true
                    var zoneGone = false, subscriptionGone = false
                    do { _ = try await database.fetchChanges(zone: zone, since: nil) } catch SyncCloudFailure.zoneNotFound { zoneGone = true }
                    catch { note("cleanup: checking the zone: \(error)") }
                    do { let exists = try await database.hasSubscription(SyncCenter.testSubscription); subscriptionGone = !exists }
                    catch { note("cleanup: checking the subscription: \(error)") }
                    check(keyGone && zoneGone && subscriptionGone && group != nil,
                          "icloudsync-real-cleanup: deleted the test zone \(zone) (gone: \(zoneGone)), its subscription (gone: "
                          + "\(subscriptionGone)) and the local test key (gone: \(keyGone))")
                    cleaned = true
                }
            }
            waitFor("the cleanup", timeout: 60) { cleaned }
        default:
            note("FAIL unknown script \(script)")
        }
    }
}
#endif

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircImport

/// Explicitly opt-in; never runs during ordinary tests. Reads only sidebar and
/// Local State/profile-directory metadata, and prints aggregate counts only.
final class LocalSmokeTests: XCTestCase, @unchecked Sendable {
    func testCountsOnly() async throws {
        guard ProcessInfo.processInfo.environment["AIRC_IMPORT_LOCAL_SMOKE"] == "1" else {
            throw XCTSkip("Local sidebar smoke test requires explicit opt-in.")
        }
        let plan: ImportPlan
        do { plan = try await ArcImporter.plan() }
        catch { XCTFail("Local parsing failed; source details suppressed."); return }
        func count(_ items: [ImportedItem]) -> (Int, Int) {
            var tabs = 0, folders = 0
            for item in items {
                switch item {
                case .tab: tabs += 1
                case .split(let x): tabs += x.tabs.count
                case .folder(let f): folders += 1; let c = count(f.children); tabs += c.0; folders += c.1
                }
            }
            return (tabs, folders)
        }
        let totals = plan.spaces.map { count($0.pinned) }
        print("profiles=\(plan.profiles.count) spaces=\(plan.spaces.count) pinnedTabs=\(totals.reduce(0) { $0 + $1.0 }) folders=\(totals.reduce(0) { $0 + $1.1 }) favorites=\(plan.favorites.values.reduce(0) { $0 + $1.count }) warnings=\(plan.warnings.count)")
        for code in Set(plan.warnings.map { $0.code.rawValue }).sorted() {
            print("warning_\(code)=\(plan.warnings.filter { $0.code.rawValue == code }.count)")
        }
    }
}

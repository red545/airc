// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import AircKit

/// review21: what the app checks "nothing changed since" by. The undo stack's count stops at `maxUndo`, so Peek's
/// "⌘Z reopens the Peek just closed" (Browser/Peek.swift) and Clear's batch join (WindowController.archiveNow) use
/// `undoGeneration` and step serials instead.
final class UndoMarkTests: XCTestCase {
    private func fill(_ s: SpacesStore) throws {
        for n in 0..<SpacesStore.maxUndo {
            let t = try s.openTab(url: "https://f\(n).example.com/", inSpace: s.selectedSpace.id)
            _ = try s.archiveTabs([t.id], reason: .manual, label: "Archive")
        }
        XCTAssertEqual(s.undoStack.count, SpacesStore.maxUndo)
    }

    /// A full stack: a new step leaves the count as it was, but not the generation (Peek reopened instead of undoing
    /// a Clear made after it closed).
    func testGenerationChangesWhenTheCountCannot() throws {
        let s = try SpacesStore(path: nil)
        try fill(s)
        let count = s.undoStack.count, generation = s.undoGeneration
        let t = try s.openTab(url: "https://clear.example.com/", inSpace: s.selectedSpace.id)
        _ = try s.archiveTabs([t.id], reason: .clear, label: "Clear Today")
        XCTAssertEqual(s.undoStack.count, count)
        XCTAssertNotEqual(s.undoGeneration, generation)
    }

    /// Below the cap: ⌘Z and a new step put the count back, the generation doesn't.
    func testGenerationChangesAfterUndoAndANewStep() throws {
        let s = try SpacesStore(path: nil)
        let a = try s.openTab(url: "https://a.example.com/", inSpace: s.selectedSpace.id)
        _ = try s.archiveTabs([a.id], reason: .manual, label: "Archive")
        let count = s.undoStack.count, generation = s.undoGeneration
        _ = try s.undo()
        let b = try s.openTab(url: "https://b.example.com/", inSpace: s.selectedSpace.id)
        _ = try s.archiveTabs([b.id], reason: .manual, label: "Archive")
        XCTAssertEqual(s.undoStack.count, count)
        XCTAssertNotEqual(s.undoGeneration, generation)
    }

    /// A Clear that writes in two batches on a full stack is still one ⌘Z.
    func testJoinByStepSerialOnAFullStack() throws {
        let s = try SpacesStore(path: nil)
        try fill(s)
        let sid = s.selectedSpace.id
        let one = try s.openTab(url: "https://one.example.com/", inSpace: sid)
        let two = try s.openTab(url: "https://two.example.com/", inSpace: sid)
        let mark = s.lastUndoSerial
        _ = try s.archiveTabs([one.id], reason: .clear, label: "Clear Today")
        let first = try XCTUnwrap(s.undoStack.last?.serial)
        XCTAssertGreaterThan(first, mark)
        _ = try s.archiveTabs([two.id], reason: .clear, label: "Clear Today")
        XCTAssertTrue(s.joinLastUndoStep(intoStep: first, label: "Clear Today"))
        XCTAssertEqual(s.undoStack.last?.serial, first)
        _ = try s.undo()
        XCTAssertNotNil(s.tab(one.id))
        XCTAssertNotNil(s.tab(two.id))
    }

    /// Another step between the batches: no join (each stays its own ⌘Z).
    func testNoJoinAcrossAnotherStep() throws {
        let s = try SpacesStore(path: nil)
        let sid = s.selectedSpace.id
        let one = try s.openTab(url: "https://one.example.com/", inSpace: sid)
        let other = try s.openTab(url: "https://other.example.com/", inSpace: sid)
        let two = try s.openTab(url: "https://two.example.com/", inSpace: sid)
        _ = try s.archiveTabs([one.id], reason: .clear, label: "Clear Today")
        let first = try XCTUnwrap(s.undoStack.last?.serial)
        _ = try s.archiveTabs([other.id], reason: .manual, label: "Archive")
        _ = try s.archiveTabs([two.id], reason: .clear, label: "Clear Today")
        XCTAssertFalse(s.joinLastUndoStep(intoStep: first, label: "Clear Today"))
        XCTAssertFalse(s.joinLastUndoStep(intoStep: try XCTUnwrap(s.undoStack.last?.serial), label: "Clear Today"))
    }
}

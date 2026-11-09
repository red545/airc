// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// `--script parityp04`'s drop target: the window's root view takes a drop over the sidebar into the current Space's
/// Today (P04), and leaves one over the page card alone. AppKit's drag session can't be posted, so the root view gets
/// what AppKit hands it: an NSDraggingInfo with the pasteboard and the drop point.
extension SnapshotRunner {
    func parityP04DropTarget(_ file: @escaping () -> URL) {
        var before = 0
        step { [self] done in
            let pb = NSPasteboard.withUniqueName()
            pb.clearContents()
            let item = NSPasteboardItem()
            item.setString(file().absoluteString, forType: .fileURL)
            pb.writeObjects([item])
            let root = c.root
            let inSidebar = root.convert(NSPoint(x: c.sidebar.frame.midX, y: c.sidebar.frame.maxY - 60), to: nil)
            let onPage = root.convert(NSPoint(x: c.card.frame.midX, y: c.card.frame.midY), to: nil)
            before = c.store.todayTabs(ofSpace: c.currentSpaceID).count
            let pageOp = root.draggingEntered(P04DragInfo(pb, at: onPage, in: c.window))
            let pageTook = root.performDragOperation(P04DragInfo(pb, at: onPage, in: c.window))
            let sidebarOp = root.draggingEntered(P04DragInfo(pb, at: inSidebar, in: c.window))
            let took = root.performDragOperation(P04DragInfo(pb, at: inSidebar, in: c.window))
            let op = SidebarFileImport.latest
            waitUntil({ op?.isFinished ?? true }, timeout: 6) {
                let today = self.c.store.todayTabs(ofSpace: self.c.currentSpaceID)
                self.check(pageOp == [] && !pageTook && sidebarOp == .copy && took && today.count == before + 1
                           && today.first?.url == file().standardizedFileURL.absoluteString,
                           "P04 drop target: a file dropped on the sidebar opens at the top of Today; over the page card the root view leaves it "
                           + "(sidebar \(sidebarOp == .copy), took \(took); page \(pageOp == []), took \(pageTook); Today \(before) → \(today.count))")
                self.c.undo()
                pb.releaseGlobally()
                done()
            }
        }
    }
}

/// What AppKit hands a drop target: the pasteboard and the drop point (window coordinates).
final class P04DragInfo: NSObject, NSDraggingInfo {
    private let pb: NSPasteboard
    private let point: NSPoint
    private weak var target: NSWindow?

    init(_ pb: NSPasteboard, at point: NSPoint, in window: NSWindow) {
        self.pb = pb
        self.point = point
        target = window
    }

    var draggingDestinationWindow: NSWindow? { target }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { point }
    var draggedImageLocation: NSPoint { point }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pb }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
#endif

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI
import AircDesign

@MainActor final class BlockingPrivateControls {
    private let popover = NSPopover()
    private weak var page: EngineTab?
    private let url: URL?
    init(page: EngineTab, center: BlockingCenter, palette: Palette) {
        self.page = page; url = page.url
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView:
            BlockingSiteRow(center: center, page: page).frame(width: 300)
                .environment(\.aircTheme, palette.resolved))
    }
    func show(anchor: NSView) { popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY) }
    func refresh(page: EngineTab?) { if page !== self.page || page?.url != url { popover.close() } }
    func close() { popover.close() }
}
extension PrivateWindowController {
    func showBlockingControls() {
        MainActor.assumeIsolated {
            guard let page = shownPage, let center = BlockingCenter.shared else { return }
            blockingSiteControls?.close()
            let controls = BlockingPrivateControls(page: page, center: center, palette: palette)
            blockingSiteControls = controls
            controls.show(anchor: sidebar.urlField.blockingButton)
        }
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
import AircKit

extension SnapshotRunner {
    func mkArchiveShots() {
        run { [self] in
            for (url, title) in [("https://www.swift.org", "The Swift Programming Language"),
                                 ("https://www.apple.com", "Apple"),
                                 ("https://en.wikipedia.org/wiki/Color_theory", "Color theory — Wikipedia")] {
                if let tab = try? c.store.openTab(url: url, inSpace: c.currentSpaceID, activate: false, title: title) {
                    _ = try? c.store.closeTab(tab.id)
                }
            }
            if c.library == nil { c.toggleLibrary() }
            c.library?.model.section = .archive
        }
        wait(0.6)
        mkWindowShot("archive-library")
    }
}
#endif

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import WebKit

// Private windows (Browser/PrivateWindow.swift): a data store that never touches the disk. On the WebKit dev engine it
// is the private session itself; in the Chromium build it holds the session's DRM pages (HybridEngine.swift). One per
// private session, shared by its windows like Chromium's off-the-record profile, and gone with the last of them.
extension WebKitEngine {
    func makePrivateProfile() -> WebKitProfile {
        WebKitProfile(directory: "private-" + UUID().uuidString, dataStore: .nonPersistent(), privateSession: true)
    }
}

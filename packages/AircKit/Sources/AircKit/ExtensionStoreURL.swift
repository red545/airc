// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

public enum ExtensionStoreURL {
    /// Match the ID, not the optional localized slug, query, fragment or trailing slash.
    public static func matches(_ value: String, extensionID: String) -> Bool {
        guard extensionID.count == 32, extensionID.utf8.allSatisfy({ (97...112).contains($0) }),
              let url = URLComponents(string: value), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.user == nil, url.password == nil else { return false }
        var path = url.path.split(separator: "/").map(String.init)
        switch url.host?.lowercased() {
        case "chromewebstore.google.com": break
        case "chrome.google.com":
            guard path.first == "webstore" else { return false }
            path.removeFirst()
        default: return false
        }
        if let last = path.last, ["reviews", "support", "related"].contains(last) { path.removeLast() }
        return (path.count == 2 || path.count == 3) && path.first == "detail" && path.last == extensionID
    }
}

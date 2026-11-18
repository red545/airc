// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

/// Native messaging hosts (`chrome.runtime.connectNative`) for Airc's Chromium.
///
/// Chromium looks for a host's manifest (`<host name>.json`) in its user data directory's `NativeMessagingHosts`
/// folder, then in `/Library/Application Support/Chromium/NativeMessagingHosts`. Apps that talk to their extension
/// (1Password's `com.1password.1password`, other password managers, …) install their manifest only for the browsers
/// they know: Chrome, Chromium, Arc, Edge, Brave. So, as Arc does, Airc also uses the manifests installed for those:
/// before the engine starts, each one not already in Airc's folder gets a symbolic link there.
///
/// - A manifest (or link) the person or an app put in Airc's folder itself always wins; Airc never changes it.
/// - Airc's own links point into the folders below. One whose manifest went away is removed; when a browser earlier in
///   the list has the same host, the link moves to it.
/// - Scripted runs use none of the Mac's hosts, unless a check names its own folders (`AIRC_NATIVE_HOST_SOURCES`).
enum NativeMessagingHosts {
    /// Folders with other browsers' manifests, first match wins: Chrome's (as Arc reads it), then Chromium's, Arc's
    /// own, and the other Chromium browsers apps install for.
    static func standardSources(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let user = [
            "Google/Chrome", "Chromium", "Arc/User Data", "Google/Chrome Beta", "Google/Chrome Dev",
            "Google/Chrome Canary", "Microsoft Edge", "BraveSoftware/Brave-Browser",
        ].map { support.appendingPathComponent($0, isDirectory: true).appendingPathComponent("NativeMessagingHosts", isDirectory: true) }
        // Chrome's system-wide folder (Chromium's own, /Library/Application Support/Chromium/…, the engine reads itself).
        return user + [URL(fileURLWithPath: "/Library/Google/Chrome/NativeMessagingHosts", isDirectory: true)]
    }

    /// The folders this run links from: the standard ones, none in scripted runs, or a check's own
    /// (`AIRC_NATIVE_HOST_SOURCES`, colon-separated).
    static func sources(_ options: LaunchOptions) -> [URL] {
        if let list = ProcessInfo.processInfo.environment["AIRC_NATIVE_HOST_SOURCES"], options.isAutomated {
            return list.split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
        }
        return options.isAutomated ? [] : standardSources()
    }

    /// Chromium's folder for this run's user data directory.
    static func destination(_ arguments: [String]) -> URL? {
        guard let arg = arguments.last(where: { $0.hasPrefix("--user-data-dir=") }) else { return nil }
        let dir = String(arg.dropFirst("--user-data-dir=".count))
        guard !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("NativeMessagingHosts", isDirectory: true)
    }

    /// Links in the background: Chromium reads a manifest only when an extension connects, never at startup.
    static func linkInBackground(arguments: [String], options: LaunchOptions) {
        let sources = sources(options)
        guard let destination = destination(arguments) else { return }
        DispatchQueue.global(qos: .utility).async {
            let result = link(from: sources, into: destination)
            if !result.isEmpty { NSLog("Airc: native messaging hosts: %@", result.joined(separator: ", ")) }
        }
    }

    /// One pass; returns what changed ("+name" linked, "-name" removed, "~name" moved), for the log and checks.
    @discardableResult
    static func link(from sources: [URL], into destination: URL, fileManager fm: FileManager = .default) -> [String] {
        var changes: [String] = []
        let sourcePaths = sources.map { $0.standardizedFileURL.path }
        // Our links: they point into one of the source folders (any source, so a link from a folder dropped from the
        // list is still ours to tidy).
        func ownLinkTarget(_ name: String) -> String? {
            let path = destination.appendingPathComponent(name).path
            guard let target = try? fm.destinationOfSymbolicLink(atPath: path) else { return nil }
            let folder = (target as NSString).deletingLastPathComponent
            let known = sourcePaths + standardSources().map { $0.standardizedFileURL.path }
            return known.contains(folder) ? target : nil
        }
        // The best manifest for each host name: the first source folder that has it.
        var best: [String: String] = [:]
        for folder in sources {
            guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names.sorted() where isManifestName(name) && best[name] == nil {
                let path = folder.appendingPathComponent(name).standardizedFileURL.path
                var isDir: ObjCBool = false
                // A dangling link or a folder isn't a manifest.
                guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { continue }
                best[name] = path
            }
        }
        let existing = (try? fm.contentsOfDirectory(atPath: destination.path)) ?? []
        // Tidy our own links: gone, or now beaten by an earlier folder.
        for name in existing where isManifestName(name) {
            guard let target = ownLinkTarget(name) else { continue }
            let path = destination.appendingPathComponent(name).path
            if let want = best[name] {
                if want != target || !fm.fileExists(atPath: target) {
                    try? fm.removeItem(atPath: path)
                    if (try? fm.createSymbolicLink(atPath: path, withDestinationPath: want)) != nil { changes.append("~" + name) }
                }
            } else {
                try? fm.removeItem(atPath: path)
                changes.append("-" + name)
            }
            best[name] = nil
        }
        let missing = best.keys.filter { !existing.contains($0) }.sorted()
        guard !missing.isEmpty else { return changes }
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in missing {
            let path = destination.appendingPathComponent(name).path
            if (try? fm.createSymbolicLink(atPath: path, withDestinationPath: best[name]!)) != nil { changes.append("+" + name) }
        }
        return changes
    }

    /// `<host name>.json`, host names as Chromium allows them (lowercase letters, digits, `.` and `_`).
    static func isManifestName(_ name: String) -> Bool {
        guard name.hasSuffix(".json") else { return false }
        let host = name.dropLast(5)
        return !host.isEmpty && !host.hasPrefix(".") && !host.hasSuffix(".") && !host.contains("..")
            && host.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "_" }
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin

/// The only extension payload reads permitted by import: bounded, read-only copies of manifest.json
/// and _locales/<language>/messages.json. Walk with openat/O_NOFOLLOW so symlinks cannot escape,
/// including if the source tree changes during import. Never enumerate or copy the extension tree.
enum ExtensionNames {
    static let maxBytes = 1_048_576

    static func resolve(id: String, entry: [String: Any], profile: URL, tempRoot: URL,
                        languages: [String] = Locale.preferredLanguages) -> String? {
        let saved = entry["manifest"] as? [String: Any] ?? [:]
        let root = profile.appendingPathComponent("Extensions")
        var path = entry["path"] as? String ?? ""
        if path.hasPrefix(root.path + "/") { path = String(path.dropFirst(root.path.count + 1)) }
        if path.isEmpty, let version = saved["version"] as? String { path = id + "/" + version + "_0" }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts[0] == id, safe(parts[1]) else { return nil }
        let scratch = tempRoot.appendingPathComponent("AircImport-" + UUID().uuidString)
        guard (try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true,
                                                       attributes: [.posixPermissions: 0o700])) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: scratch) }
        func json(_ tail: [String]) -> [String: Any]? {
            // profile itself was checked by readProfileData. Its child directories must not be symlinks.
            var fd = open(profile.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            let components = ["Extensions"] + parts + tail
            for (index, component) in components.enumerated() {
                let last = index == components.count - 1
                let next = openat(fd, component, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | (last ? 0 : O_DIRECTORY))
                guard next >= 0 else { return nil }
                close(fd); fd = next
            }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_size <= maxBytes else { return nil }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            guard let data = try? handle.read(upToCount: maxBytes + 1), data.count <= maxBytes else { return nil }
            let copy = scratch.appendingPathComponent("metadata.json")
            do {
                try data.write(to: copy, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: copy.path)
                return try JSONSerialization.jsonObject(with: Data(contentsOf: copy)) as? [String: Any]
            } catch { return nil }
        }
        guard let manifest = json(["manifest.json"]), let name = manifest["name"] as? String else { return nil }
        guard name.hasPrefix("__MSG_"), name.hasSuffix("__") else { return name.isEmpty ? nil : name }
        let key = String(name.dropFirst(6).dropLast(2)).lowercased()
        var locales: [String] = []
        for language in languages {
            let normalized = language.replacingOccurrences(of: "-", with: "_")
            locales.append(normalized)
            locales.append(String(normalized.split(separator: "_").first ?? ""))
        }
        locales += [manifest["default_locale"] as? String ?? "", "en"]
        var seen = Set<String>()
        for locale in locales where safe(locale) && seen.insert(locale).inserted {
            guard let messages = json(["_locales", locale, "messages.json"]),
                  let row = messages.first(where: { $0.key.lowercased() == key })?.value as? [String: Any],
                  let message = row["message"] as? String, !message.isEmpty, !message.hasPrefix("__MSG_") else { continue }
            return message
        }
        return nil
    }

    private static func safe(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".."
            && component.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }
    }
}

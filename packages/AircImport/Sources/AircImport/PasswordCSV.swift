// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// Saved passwords from a CSV file the user exported from their browser and chose in an open panel. This is the only
/// way passwords from other browsers come over: their own password stores and Keychain items are never read.
/// The columns Chrome (and Edge, Brave, Vivaldi, Opera), Firefox and Safari write:
///   - Chrome: `name,url,username,password,note`
///   - Firefox: `"url","username","password","httpRealm","formActionOrigin","guid","timeCreated",…`
///   - Safari (the Passwords app): `Title,URL,Username,Password,Notes,OTPAuth`
/// Columns are found by name, so their order doesn't matter. Values are never logged, and no error or count carries
/// one; the caller hands `logins` to the engine's password store and drops them.
public struct PasswordFile: Sendable {
    public enum Format: String, Sendable { case chrome, firefox, safari, other }
    public var format: Format
    public var logins: [ImportedLogin]
    /// Data rows in the file (the header not counted).
    public var rows = 0
    /// The same site and username a second time in the file (the first one is kept, as Chrome keeps it).
    public var duplicates = 0
    /// Rows without a password or an address.
    public var incomplete = 0
    /// Logins that aren't for a website: app logins (`android://`), Firefox's own account entry.
    public var notWebsite = 0
    /// Rows past `PasswordCSV.maxRows`, or with fewer fields than the header names.
    public var unreadable = 0
}

public enum PasswordCSV {
    public static let maxRows = 100_000
    public static let maxFileSize = 64 << 20

    /// Reads the chosen file off the caller's actor.
    public static func read(_ url: URL) async throws -> PasswordFile {
        try await Task.detached {
            try parse(BrowserImporter.readLimited(url, limit: maxFileSize))
        }.value
    }

    public static func parse(_ data: Data) throws -> PasswordFile {
        var bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        guard String(bytes: bytes, encoding: .utf8) != nil else { throw ImportError.invalidPasswordFile }
        var records = PasswordCSV.records(bytes)
        guard !records.isEmpty else { throw ImportError.invalidPasswordFile }
        let header = records.removeFirst().map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func column(_ names: [String]) -> Int? { names.lazy.compactMap { header.firstIndex(of: $0) }.first }
        guard let url = column(["url", "login_uri", "website", "web site", "login url", "origin", "hostname", "address"]),
              let password = column(["password", "login_password"]) else { throw ImportError.invalidPasswordFile }
        let username = column(["username", "login_username", "user name", "login", "user", "email"])
        let action = column(["formactionorigin", "action_url", "form action"])
        let format: PasswordFile.Format =
            header.contains("formactionorigin") || header.contains("httprealm") ? .firefox
            : header.contains("otpauth") || header.first == "title" ? .safari
            : header.first == "name" && url == 1 ? .chrome : .other
        var out = PasswordFile(format: format, logins: [])
        var seen = Set<String>()
        for (i, r) in records.enumerated() {
            // A blank line, or Excel's trailing empty row.
            if r.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            out.rows += 1
            guard i < maxRows, r.count > max(url, password) else { out.unreadable += 1; continue }
            let pass = r[password]
            let address = r[url].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pass.isEmpty, !address.isEmpty else { out.incomplete += 1; continue }
            guard let site = origin(address) else { out.notWebsite += 1; continue }
            let user = username.flatMap { $0 < r.count ? r[$0] : nil } ?? ""
            guard seen.insert(site.realm + "\u{1f}" + site.origin + "\u{1f}" + user).inserted else { out.duplicates += 1; continue }
            let formAction = action.flatMap { $0 < r.count ? origin(r[$0])?.origin : nil } ?? ""
            out.logins.append(ImportedLogin(origin: site.origin, actionURL: formAction, signonRealm: site.realm, username: user, password: pass))
        }
        return out
    }

    /// The page a login is for, as Chromium stores it (no query or fragment), and its realm (`https://host[:port]/`).
    /// nil for anything but an http(s) address with a host. A bare host ("example.com") is taken as https.
    static func origin(_ raw: String) -> (origin: String, realm: String)? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://"), !text.contains(":"), text.contains("."), !text.contains(" ") { text = "https://" + text }
        guard var c = URLComponents(string: text), let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host?.lowercased(), !host.isEmpty else { return nil }
        c.scheme = scheme
        c.host = host
        c.user = nil
        c.password = nil
        c.query = nil
        c.fragment = nil
        if (scheme == "https" && c.port == 443) || (scheme == "http" && c.port == 80) { c.port = nil }
        if c.path.isEmpty { c.path = "/" }
        let port = c.port.map { ":\($0)" } ?? ""
        return (c.string ?? "\(scheme)://\(host)\(port)/", "\(scheme)://\(host)\(port)/")
    }

    /// RFC 4180: fields separated by commas, quoted with `"` (a quote inside written `""`), records ending in LF, CRLF
    /// or CR outside quotes.
    static func records(_ bytes: [UInt8]) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field: [UInt8] = []
        var quoted = false
        var i = 0
        let n = bytes.count
        func endField() { record.append(String(decoding: field, as: UTF8.self)); field.removeAll(keepingCapacity: true) }
        func endRecord() { endField(); records.append(record); record = [] }
        while i < n {
            let c = bytes[i]
            if quoted {
                if c == 0x22 {
                    if i + 1 < n, bytes[i + 1] == 0x22 { field.append(0x22); i += 1 } else { quoted = false }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case 0x22 where field.isEmpty: quoted = true
                case 0x2C: endField()
                case 0x0D:
                    endRecord()
                    if i + 1 < n, bytes[i + 1] == 0x0A { i += 1 }
                case 0x0A: endRecord()
                default: field.append(c)
                }
            }
            i += 1
            if records.count > maxRows + 1 { return records }
        }
        if !field.isEmpty || !record.isEmpty { endRecord() }
        return records
    }
}

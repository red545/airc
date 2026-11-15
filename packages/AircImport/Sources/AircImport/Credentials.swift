// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation
import Security
import CArcCrypto

public struct ImportedLogin: Codable, Sendable, Equatable {
    public var origin: String
    public var actionURL: String
    public var signonRealm: String
    public var username: String
    public var password: String
    /// P22b: "" for a web page's form; "basic", "digest" or "other" for HTTP authentication (the browser's own sign-in
    /// box), whose realm is the origin plus the server's realm name.
    public var scheme = ""
    /// P22b: a federated sign-in's provider ("https://accounts.google.com"). It has no password.
    public var federationOrigin = ""
    /// P22b: the Android app this login was saved for, when Arc's affiliations link the app to this website.
    public var androidApp = ""
}
/// What the destination engine's import takes beyond website passwords and unpartitioned cookies (P22b), from the
/// engine's own list (`AircProfile.importKinds`). An engine without the list takes none of them.
public struct ImportKinds: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let httpAuthLogins = ImportKinds(rawValue: 1)
    public static let federatedLogins = ImportKinds(rawValue: 2)
    public static let partitionedCookies = ImportKinds(rawValue: 4)
    public static let localStorage = ImportKinds(rawValue: 8)
    public static let all: ImportKinds = [.httpAuthLogins, .federatedLogins, .partitionedCookies, .localStorage]
    public init(names: [String]) {
        let known: [String: ImportKinds] = ["httpAuthLogins": .httpAuthLogins, "federatedLogins": .federatedLogins,
                                            "partitionedCookies": .partitionedCookies, "localStorage": .localStorage]
        self = ImportKinds(names.compactMap { known[$0] })
    }
}
public struct ImportedCookie: Codable, Sendable, Equatable {
    public var host: String
    public var name: String
    public var path: String
    public var value: String
    /// Chromium microseconds since 1601-01-01; zero means a session cookie.
    public var expiresUTC: Int64
    public var secure: Bool
    public var httpOnly: Bool
    public var sameSite: Int
    public var metadata: [String: String]
}
public struct ImportedCredentials: Sendable {
    public var logins: [ImportedLogin]
    public var cookies: [ImportedCookie]
    /// P22b: the localStorage of the sites visited most (SiteStorage.swift).
    public var siteData: [ImportedSiteStorage] = []
    /// Arc's "never save" entries, which aren't brought over.
    public var skippedLogins = 0
    /// Rows that couldn't be read or decrypted. One bad row never stops the rest of the profile (code review H2).
    public var failedLogins = 0
    public var failedCookies = 0
    /// Databases that couldn't be read at all ("Login Data", "Cookies"); the other one still comes over.
    public var failedDatabases: [String] = []
    /// Why each of `failedDatabases` couldn't be read, in words (P22): Arc kept writing to it, it is damaged, macOS
    /// didn't allow reading it. Never a value from it.
    public var databaseReasons: [String: String] = [:]
    /// Every encrypted value this read tried failed to decrypt (P22): the key from "Arc Safe Storage" isn't the one Arc
    /// encrypted them with (the item was reset, or the data came from another Mac).
    public var keyMismatch: Bool { encryptedRows > 0 && undecryptableRows == encryptedRows }
    var encryptedRows = 0
    var undecryptableRows = 0
    /// Why rows failed, with counts. Never contains a value.
    public var problems: [String: Int] = [:]
    /// The rows that didn't come over at read time, one each, for the per-row results (site and username only, never a
    /// password or a cookie's value).
    public var notes: [RowNote] = []

    public struct RowNote: Sendable, Equatable {
        public enum Kind: String, Sendable { case login, cookie, siteData }
        public var kind: Kind
        /// A login's origin, a cookie's host, a site's origin (site data).
        public var site: String
        /// A login's username ("" for a cookie or a never-save entry).
        public var username: String
        /// Skipped on purpose (Arc's never-save entries); otherwise the row couldn't be read.
        public var skipped: Bool
        public var reason: String
        /// P22b: a federated sign-in's provider host ("accounts.google.com").
        public var provider = ""
        /// P22b: what of a site's data this is ("local storage", "offline data").
        public var detail = ""
        /// P22b: how many it stands for (sites beyond the most visited ones are one note).
        public var count = 1

        public init(kind: Kind, site: String, username: String = "", skipped: Bool, reason: String, provider: String = "",
                    detail: String = "", count: Int = 1) {
            self.kind = kind
            self.site = site
            self.username = username
            self.skipped = skipped
            self.reason = reason
            self.provider = provider
            self.detail = detail
            self.count = count
        }
    }

    public init(logins: [ImportedLogin] = [], cookies: [ImportedCookie] = []) {
        self.logins = logins
        self.cookies = cookies
    }

    mutating func fail(_ problem: String) { problems[problem, default: 0] += 1 }
}

public enum ArcSafeStorage {
    /// Keychain's lookup, replaceable so tests can give any status without the real Keychain (P22).
    public typealias Lookup = (_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus

    /// The Keychain item Arc keeps its key in: generic password "Arc Safe Storage", account "Arc", in the login
    /// keychain. Checks name a scratch item instead (arcimport3); the app reads only `.arc`.
    public struct Item: Sendable, Equatable {
        public var service: String
        public var account: String
        public init(service: String, account: String) { self.service = service; self.account = account }
        public static let arc = Item(service: "Arc Safe Storage", account: "Arc")
    }

    /// Explicit opt-in only. This may display the system Keychain consent prompt. `searchList` limits the lookup to
    /// those keychains (a check's scratch keychain); nil searches the user's keychains as macOS does.
    public static func readPassword(item: Item = .arc, searchList: [AnyObject]? = nil,
                                    lookup: Lookup = SecItemCopyMatching) throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecAttrAccount as String: item.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let searchList { query[kSecMatchSearchList as String] = searchList }
        var result: CFTypeRef?
        let status = lookup(query as CFDictionary, &result)
        if let error = error(for: status) { throw error }
        guard let data = result as? Data, !data.isEmpty else { throw ImportError.keychainUnavailable }
        return data
    }

    /// What a Keychain status means for the import, nil for success. Denied or cancelled prompts and a wrong password
    /// are the person's answer; a locked keychain (or no way to ask) and a missing item are said as such.
    public static func error(for status: OSStatus) -> ImportError? {
        switch status {
        case errSecSuccess: nil
        case errSecUserCanceled, errSecAuthFailed: .keychainDeclined
        case errSecInteractionNotAllowed, errSecNotAvailable: .keychainLocked
        case errSecItemNotFound, errSecNoSuchKeychain: .keychainNotFound
        default: .keychainUnavailable
        }
    }
    public static func deriveKey(password: Data) throws -> Data {
        var key = Data(count: 16)
        let salt = Data("saltysalt".utf8)
        let status = key.withUnsafeMutableBytes { out in
            password.withUnsafeBytes { pass in
                salt.withUnsafeBytes { s in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pass.baseAddress?.assumingMemoryBound(to: Int8.self), password.count, s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, out.baseAddress?.assumingMemoryBound(to: UInt8.self), 16)
                }
            }
        }
        guard status == kCCSuccess else { throw ImportError.decryptionFailed }
        return key
    }
    public static func decrypt(_ encrypted: Data, key: Data) throws -> Data {
        guard encrypted.prefix(3) == Data("v10".utf8) else { throw ImportError.unsupportedEncryption }
        guard encrypted.count > 3, (encrypted.count - 3) % 16 == 0 else { throw ImportError.decryptionFailed }
        return try crypt(Data(encrypted.dropFirst(3)), key: key, operation: CCOperation(kCCDecrypt))
    }
    /// Encrypts the way Chromium's "v10" does on macOS. For synthetic fixtures only (tests and the app's synthetic
    /// import check); never used on real data.
    public static func encryptForTests(_ plain: Data, key: Data) throws -> Data {
        Data("v10".utf8) + (try crypt(plain, key: key, operation: CCOperation(kCCEncrypt)))
    }
    /// The SHA-256 of a cookie's host, which prefixes the plaintext value from cookie schema 24 on.
    public static func digest(_ host: String) -> Data { hash(host) }
    static func crypt(_ input: Data, key: Data, operation: CCOperation) throws -> Data {
        guard key.count == 16 else { throw ImportError.decryptionFailed }
        let iv = Data(repeating: 32, count: 16)
        var output = Data(count: input.count + 16); var moved = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { source in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), k.baseAddress, 16, v.baseAddress, source.baseAddress, input.count, out.baseAddress, capacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw ImportError.decryptionFailed }
        return output.prefix(moved)
    }
    static func hash(_ host: String) -> Data {
        var result = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        let data = Data(host.utf8)
        _ = result.withUnsafeMutableBytes { out in data.withUnsafeBytes { p in CC_SHA256(p.baseAddress, CC_LONG(data.count), out.baseAddress?.assumingMemoryBound(to: UInt8.self)) } }
        return result
    }
}

/// A private copy of one of Arc's databases. Arc keeps them open while it runs (Login Data with SQLite's exclusive
/// lock), so they are never opened in place: the database and its -wal, -shm and -journal files are copied into a 0700
/// folder, and the copy is retried until no source file changed during it, so the files belong together. SQLite then
/// opens the copy, which replays committed WAL pages and rolls back a half-written transaction. The folder is deleted
/// when the copy is released, and `ArcCredentialImporter.removeStaleCopies` removes any a crash left behind.
final class DatabaseCopy {
    static let folderPrefix = "AircImport-"

    /// Why a copy couldn't be made or opened (P22). Its description is `ImportError.databaseFailed`'s.
    struct Problem: Error, LocalizedError, Equatable {
        enum Kind: Equatable { case missing, busy, damaged }
        var kind: Kind
        var errorDescription: String? { ImportError.databaseFailed.errorDescription }
    }
    private(set) var db: OpaquePointer?
    let folder: URL

    init(_ source: URL, tempRoot: URL, immutableOnly: Bool = false) throws {
        let fm = FileManager.default
        folder = tempRoot.appendingPathComponent(Self.folderPrefix + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let files = (immutableOnly ? [""] : ["", "-wal", "-shm", "-journal"]).map { URL(fileURLWithPath: source.path + $0) }
            func stamp() -> [String] {
                files.map { f in
                    guard let a = try? fm.attributesOfItem(atPath: f.path) else { return "-" }
                    return "\((a[.size] as? NSNumber)?.int64Value ?? -1)@\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
                }
            }
            let copy = folder.appendingPathComponent("copy.sqlite")
            var consistent = false
            for attempt in 0..<8 where !consistent {
                if attempt > 0 { Thread.sleep(forTimeInterval: 0.05 * Double(attempt)) }
                for f in files { try? fm.removeItem(atPath: copy.path + f.path.dropFirst(source.path.count)) }
                let before = stamp()
                guard before[0] != "-" else { throw Problem(kind: .missing) }
                for f in files where fm.fileExists(atPath: f.path) {
                    // A file macOS won't let us read says so, rather than looking damaged (P22).
                    guard fm.isReadableFile(atPath: f.path) else { throw ImportError.permissionDenied }
                    do { try fm.copyItem(at: f, to: URL(fileURLWithPath: copy.path + f.path.dropFirst(source.path.count))) }
                    catch let e as NSError where e.code == NSFileReadNoPermissionError { throw ImportError.permissionDenied }
                }
                consistent = stamp() == before
            }
            // Arc wrote to it during every attempt.
            guard consistent else { throw Problem(kind: .busy) }
            // Arc history reads only a checkpointed main file. Never open the source in SQLite.
            let path = immutableOnly ? copy.absoluteString + "?mode=ro&immutable=1" : copy.path
            let flags = immutableOnly ? SQLITE_OPEN_READONLY | SQLITE_OPEN_URI : SQLITE_OPEN_READWRITE
            guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK,
                  sqlite3_exec(db, "SELECT count(*) FROM sqlite_master", nil, nil, nil) == SQLITE_OK else {
                throw Problem(kind: .damaged)
            }
        } catch {
            sqlite3_close(db); db = nil
            try? fm.removeItem(at: folder)
            throw error
        }
    }

    deinit { sqlite3_close(db); try? FileManager.default.removeItem(at: folder) }

    func rows(_ query: String) throws -> [[String: Data]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { throw ImportError.databaseFailed }
        defer { sqlite3_finalize(statement) }
        var rows: [[String: Data]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw ImportError.databaseFailed }
            var row: [String: Data] = [:]
            for i in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, i))
                if sqlite3_column_type(statement, i) == SQLITE_BLOB {
                    let count = Int(sqlite3_column_bytes(statement, i))
                    row[name] = sqlite3_column_blob(statement, i).map { Data(bytes: $0, count: count) } ?? Data()
                } else if let text = sqlite3_column_text(statement, i) { row[name] = Data(String(cString: text).utf8) }
            }
            rows.append(row)
        }
        return rows
    }
}

public enum ArcCredentialImporter {
    /// Library only: does not write to the destination browser or fetch Keychain
    /// implicitly. Call ArcSafeStorage.readPassword explicitly after user consent.
    /// Works while Arc runs: it reads private copies (`DatabaseCopy`). A row that can't be decrypted is counted in
    /// `failedLogins`/`failedCookies` and the rest still comes over; a database that can't be read at all is listed in
    /// `failedDatabases`. Throws only for cancellation or an unreadable profile folder.
    /// P22b: `kinds` are what the destination engine takes beyond website passwords (HTTP authentication and federated
    /// logins come through only then, otherwise they're skipped with why and never decrypted); `includeSiteData` reads
    /// the most visited sites' localStorage (SiteStorage.swift).
    public static func read(profileDirectory: URL, key: Data, includeLogins: Bool = true, includeCookies: Bool = true,
                            includeSiteData: Bool = false, kinds: ImportKinds = [],
                            progress: ProgressHandler? = nil,
                            tempRoot: URL = FileManager.default.temporaryDirectory) async throws -> ImportedCredentials {
        try await Task.detached {
            var out = ImportedCredentials()
            func exists(_ url: URL) throws -> Bool {
                do { _ = try url.resourceValues(forKeys: [.isRegularFileKey]); return true }
                catch { if (error as NSError).code == NSFileReadNoSuchFileError { return false }; throw ImportError.permissionDenied }
            }
            func string(_ row: [String: Data], _ key: String) -> String { String(data: row[key] ?? Data(), encoding: .utf8) ?? "" }
            /// `decrypted`: the bytes came out of `decrypt`, so bytes that aren't text may mean another key.
            func text(_ data: Data, decrypted: Bool = true) throws -> String {
                guard let s = String(data: data, encoding: .utf8) else {
                    guard decrypted else { throw RowProblem("damaged in Arc (not text)") }
                    out.undecryptableRows += 1
                    throw RowProblem("damaged in Arc, or encrypted with another key (not text once decrypted)")
                }
                return s
            }
            func decrypt(_ data: Data) throws -> Data {
                if data.prefix(3) == Data("v11".utf8) { throw RowProblem("encrypted in a way Airc can't read (Chromium's “v11”, not the Mac's “v10”)") }
                guard data.prefix(3) == Data("v10".utf8) else { throw RowProblem("encrypted in a way Airc can't read (not Chromium's Mac “v10”)") }
                out.encryptedRows += 1
                do { return try ArcSafeStorage.decrypt(data, key: key) }
                catch { out.undecryptableRows += 1; throw RowProblem("couldn't be decrypted with Arc's key") }
            }
            /// A whole database that couldn't be read, in words (never a value from it).
            func databaseReason(_ error: Error) -> String {
                switch error {
                case let p as DatabaseCopy.Problem where p.kind == .busy: "Arc kept writing to it while Airc copied it. Quit Arc and try again."
                case let p as DatabaseCopy.Problem where p.kind == .missing: "It disappeared while Airc read it. Try again."
                case let e as ImportError where e == .permissionDenied: "macOS didn't let Airc read it."
                default: "It's damaged, or isn't the kind of database Arc writes."
                }
            }
            try Task.checkCancellation()
            progress?(.init(stage: .logins, completed: 0, total: 2))
            let loginURL = profileDirectory.appendingPathComponent("Login Data")
            if includeLogins, try exists(loginURL) {
                do {
                    let rows = try DatabaseCopy(loginURL, tempRoot: tempRoot).rows("SELECT * FROM logins")
                    // Android logins come over for the websites Arc's affiliations link to their app (P22b).
                    let apps = rows.contains { string($0, "signon_realm").hasPrefix("android://") }
                        ? Self.affiliations(profileDirectory, tempRoot: tempRoot) : [:]
                    var mapped: [ImportedLogin] = []
                    for r in rows {
                        try Task.checkCancellation()
                        if string(r, "blacklisted_by_user") == "1" {
                            out.skippedLogins += 1
                            out.notes.append(.init(kind: .login, site: string(r, "origin_url"), skipped: true,
                                                   reason: "Arc was set to never save passwords here"))
                            continue
                        }
                        let site = string(r, "origin_url"), username = string(r, "username_value")
                        // Kinds of login Airc doesn't take, said precisely (P22) and never decrypted. P22b: the ones the
                        // engine takes come through; a federated one needs no decrypting (it has no password).
                        let kind = Self.loginKind(r, string, kinds: kinds, apps: apps)
                        switch kind {
                        case .skip(let why, let provider):
                            out.skippedLogins += 1
                            out.notes.append(.init(kind: .login, site: site, username: username, skipped: true, reason: why, provider: provider))
                            continue
                        case .federated(let provider):
                            out.logins.append(.init(origin: site, actionURL: string(r, "action_url"), signonRealm: string(r, "signon_realm"),
                                                    username: username, password: "", federationOrigin: provider))
                            continue
                        case .password, .httpAuth, .android: break
                        }
                        do {
                            let encrypted = r["password_value"] ?? Data()
                            let password = encrypted.isEmpty ? "" : try text(decrypt(encrypted))
                            guard !password.isEmpty else {
                                out.skippedLogins += 1
                                out.notes.append(.init(kind: .login, site: site, username: username,
                                                       skipped: true, reason: "Arc saved a username here but no password"))
                                continue
                            }
                            switch kind {
                            case .android(let app, let websites):
                                // After the profile's own website logins, so a website's own password for the same
                                // username wins (the engine keeps the first; this one is then "Already saved").
                                for w in websites {
                                    mapped.append(.init(origin: w, actionURL: "", signonRealm: w, username: username, password: password,
                                                        androidApp: app))
                                }
                            case .httpAuth(let scheme):
                                out.logins.append(.init(origin: site, actionURL: "", signonRealm: string(r, "signon_realm"),
                                                        username: username, password: password, scheme: scheme))
                            default:
                                out.logins.append(.init(origin: site, actionURL: string(r, "action_url"),
                                                        signonRealm: string(r, "signon_realm"), username: username,
                                                        password: password))
                            }
                        } catch let p as RowProblem {
                            out.failedLogins += 1; out.fail("login: " + p.reason)
                            out.notes.append(.init(kind: .login, site: string(r, "origin_url"), username: string(r, "username_value"),
                                                   skipped: false, reason: p.reason))
                        }
                    }
                    out.logins += mapped
                } catch is CancellationError { throw CancellationError() }
                catch {
                    out.failedDatabases.append("Login Data"); out.fail("Login Data: \(error)")
                    out.databaseReasons["Login Data"] = databaseReason(error)
                }
            }
            progress?(.init(stage: .cookies, completed: 1, total: 2))
            var cookieURL = profileDirectory.appendingPathComponent("Network/Cookies")
            if includeCookies, try !exists(cookieURL) { cookieURL = profileDirectory.appendingPathComponent("Cookies") }
            if includeCookies, try exists(cookieURL) {
                do {
                    let db = try DatabaseCopy(cookieURL, tempRoot: tempRoot)
                    let version = Int(try db.rows("SELECT value FROM meta WHERE key = 'version'").first.map { string($0, "value") } ?? "") ?? 0
                    for r in try db.rows("SELECT * FROM cookies") {
                        try Task.checkCancellation()
                        do {
                            let host = string(r, "host_key"), encrypted = r["encrypted_value"] ?? Data()
                            var value = r["value"] ?? Data()
                            if !encrypted.isEmpty {
                                value = try decrypt(encrypted)
                                if version >= 24 {
                                    guard value.count >= 32, value.prefix(32) == ArcSafeStorage.hash(host) else {
                                        out.undecryptableRows += 1
                                        throw RowProblem("damaged in Arc, or encrypted with another key (its site check doesn't match)")
                                    }
                                    value = value.dropFirst(32)
                                }
                            }
                            var metadata: [String: String] = [:]
                            for (k, v) in r where !["encrypted_value", "value"].contains(k) { metadata[k] = String(data: v, encoding: .utf8) }
                            out.cookies.append(.init(host: host, name: string(r, "name"), path: string(r, "path"), value: try text(value, decrypted: !encrypted.isEmpty),
                                                     expiresUTC: Int64(string(r, "expires_utc")) ?? 0, secure: string(r, "is_secure") == "1",
                                                     httpOnly: string(r, "is_httponly") == "1", sameSite: Int(string(r, "samesite")) ?? -1,
                                                     metadata: metadata))
                        } catch let p as RowProblem {
                            out.failedCookies += 1; out.fail("cookie: " + p.reason)
                            out.notes.append(.init(kind: .cookie, site: string(r, "host_key"), skipped: false, reason: p.reason))
                        }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    out.failedDatabases.append("Cookies"); out.fail("Cookies: \(error)")
                    out.databaseReasons["Cookies"] = databaseReason(error)
                }
            }
            if includeSiteData { try Self.readSiteData(profileDirectory, tempRoot: tempRoot, into: &out) }
            progress?(.init(stage: .complete, completed: 2, total: 2))
            return out
        }.value
    }

    /// What a login row is, from Chromium's `logins` columns (P22, P22b): a website's password; HTTP authentication
    /// (the browser's own sign-in box, Chromium's schemes 1–3) or a federated sign-in ("Sign in with Google", no
    /// password) when the engine takes them; an Android app's login for the websites linked to it; or skipped, with
    /// why (an Android app no website is linked to, a proxy's sign-in, a username-only entry, or what the engine
    /// doesn't take yet).
    enum LoginKind: Equatable {
        case password
        case httpAuth(scheme: String)
        case federated(provider: String)
        case android(app: String, websites: [String])
        case skip(String, provider: String)
    }

    static func loginKind(_ r: [String: Data], _ string: ([String: Data], String) -> String, kinds: ImportKinds,
                          apps: [String: [String]]) -> LoginKind {
        let realm = string(r, "signon_realm"), origin = string(r, "origin_url")
        if realm.hasPrefix("android://") || origin.hasPrefix("android://") {
            let facet = realm.hasPrefix("android://") ? realm : origin
            let app = String(facet.split(separator: "@", maxSplits: 1).last ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let websites = apps[facet.hasSuffix("/") ? String(facet.dropLast()) : facet], !websites.isEmpty {
                return .android(app: app, websites: websites)
            }
            return .skip("An Android app's login" + (app.isEmpty ? "" : " (\(app))")
                         + ": no website is linked to the app, so it can't be imported", provider: "")
        }
        let federation = string(r, "federation_url")
        if realm.hasPrefix("federation://") || !federation.isEmpty {
            let provider = URL(string: federation)?.host ?? String(realm.dropFirst("federation://".count).split(separator: "/").dropFirst().first ?? "")
            if kinds.contains(.federatedLogins), federation.hasPrefix("https://") { return .federated(provider: federation) }
            return .skip("Signs in through another account (such as Google), so Arc had no password for it: use that sign-in on the site",
                         provider: provider)
        }
        let scheme = Int(string(r, "scheme")) ?? 0
        switch scheme {
        case 1, 2, 3:
            // Chromium's realm for a site's sign-in box is its origin plus the server's realm name; a proxy's is
            // host:port, which Airc doesn't take.
            let site = URL(string: origin).flatMap { u in u.scheme.flatMap { s in u.host.map { "\(s)://\($0)" + (u.port.map { ":\($0)" } ?? "") + "/" } } }
            guard let site, origin.hasPrefix("http"), realm.hasPrefix(site), realm.count > site.count else {
                return .skip("A proxy server's sign-in (HTTP authentication): Airc takes websites' only", provider: "")
            }
            guard kinds.contains(.httpAuthLogins) else {
                return .skip("A password for the browser's own sign-in box (HTTP authentication): Airc can't import these yet", provider: "")
            }
            return .httpAuth(scheme: scheme == 1 ? "basic" : scheme == 2 ? "digest" : "other")
        case 4: return .skip("Arc saved a username here but no password", provider: "")
        default: return .password
        }
    }

    /// Arc's affiliations (Chromium's "Affiliation Database"): each Android app's facet ("android://<hash>@<package>")
    /// and the HTTPS websites in its class, as login origins ("https://example.com/"), at most three. Empty when Arc has
    /// none or it can't be read.
    static func affiliations(_ profileDirectory: URL, tempRoot: URL) -> [String: [String]] {
        let url = profileDirectory.appendingPathComponent("Affiliation Database")
        guard FileManager.default.fileExists(atPath: url.path),
              let rows = try? DatabaseCopy(url, tempRoot: tempRoot).rows("""
                  SELECT a.facet_uri AS app, w.facet_uri AS web FROM eq_class_members a
                  JOIN eq_class_members w ON a.set_id = w.set_id
                  WHERE a.facet_uri LIKE 'android://%' AND w.facet_uri LIKE 'https://%' ORDER BY w.id
                  """) else { return [:] }
        var out: [String: [String]] = [:]
        for r in rows {
            guard let app = r["app"].flatMap({ String(data: $0, encoding: .utf8) }),
                  let web = r["web"].flatMap({ String(data: $0, encoding: .utf8) }),
                  let u = URL(string: web), u.scheme == "https", let host = u.host, !host.isEmpty else { continue }
            let site = "https://" + host.lowercased() + (u.port.map { ":\($0)" } ?? "") + "/"
            if out[app, default: []].count < 3, !out[app, default: []].contains(site) { out[app, default: []].append(site) }
        }
        return out
    }

    /// Removes private copies a crash left behind (only folders named like `DatabaseCopy`'s, in `tempRoot`).
    public static func removeStaleCopies(tempRoot: URL = FileManager.default.temporaryDirectory) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: tempRoot.path)) ?? [] where name.hasPrefix(DatabaseCopy.folderPrefix) {
            try? fm.removeItem(at: tempRoot.appendingPathComponent(name))
        }
    }
}

/// Why one row couldn't be imported. Never carries the row's value.
struct RowProblem: Error {
    var reason: String
    init(_ reason: String) { self.reason = reason }
}

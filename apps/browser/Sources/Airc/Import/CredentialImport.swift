// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircImport
import AircKit
import Foundation
import Security

// Arc logins and cookies (IM-2). Read only after the user presses "Import logins", which is what makes macOS ask for
// the Keychain item "Arc Safe Storage". Never in automated runs (snapshots, tests): `LaunchOptions.isAutomated`, except
// with a synthetic folder and a synthetic key (the real-event check in CredentialCheck.swift; test builds only).
//
// They go straight into the engine's own password and cookie stores, which re-encrypt them with Airc's key
// ("Airc Safe Storage", engine/PROFILE-SERVICES.md). Nothing holds the plaintext afterwards (code review H1). On WebKit,
// which can't take Chromium passwords, nothing is read or decrypted at all.

/// Where decrypted logins and cookies go.
protocol CredentialSink: AnyObject {
    /// False on an engine that can't take Chromium logins (WebKit): the import doesn't start, nothing is decrypted.
    var acceptsCredentials: Bool { get }
    /// Called once per Airc profile, on the main thread. The values are plaintext: hand them over and drop them.
    /// `completion` gets the engine's own counts.
    func receive(_ credentials: ImportedCredentials, forProfile profileID: String,
                 completion: @escaping (CredentialImport.EngineResult) -> Void)
}

/// The engine's stores: `AircProfile importLogins:/importCookies:` through `ChromiumEngine.importCredentials`.
final class EngineCredentialSink: CredentialSink {
    typealias Importer = (_ logins: [[String: Any]], _ cookies: [[String: Any]], _ profile: EngineProfile,
                          _ completion: @escaping ([String: Any], [String: Any]) -> Void) -> Void
    private let profiles: ProfileHost
    private let importer: Importer?
    /// How long to wait for the engine's answer before counting the profile as failed (its callbacks can be dropped
    /// when the engine shuts down).
    var timeout: TimeInterval = 90

    var acceptsCredentials: Bool { importer != nil }

    init(profiles: ProfileHost, importer: Importer?) {
        self.profiles = profiles
        self.importer = importer
    }

    static func make(engine: BrowserEngine, profiles: ProfileHost) -> EngineCredentialSink {
        #if canImport(AircCore)
        if let chromium = engine as? ChromiumEngine {
            return EngineCredentialSink(profiles: profiles) { [weak chromium] logins, cookies, profile, done in
                guard let chromium else { return done(["error": "engine stopped"], ["error": "engine stopped"]) }
                chromium.importCredentials(logins: logins, cookies: cookies, into: profile, completion: done)
            }
        }
        #endif
        return EngineCredentialSink(profiles: profiles, importer: nil)
    }

    func receive(_ credentials: ImportedCredentials, forProfile profileID: String,
                 completion: @escaping (CredentialImport.EngineResult) -> Void) {
        let sent = (logins: credentials.logins.count, cookies: credentials.cookies.count)
        // Nothing stored: every row failed, for the same reason.
        func failure(_ why: String) -> CredentialImport.EngineResult {
            var r = CredentialImport.EngineResult.failed(sent, why)
            let reason = why.prefix(1).uppercased() + why.dropFirst()
            r.rows = CredentialImport.rows(
                logins: credentials.logins, loginResults: credentials.logins.indices.map { ["index": $0, "status": "failed", "reason": reason] },
                cookies: credentials.cookies, cookieResults: credentials.cookies.indices.map { ["index": $0, "status": "rejected", "reason": "store unavailable"] },
                profileID: profileID).map { var row = $0; row.status = .failed; row.reason = reason; return row }
            return r
        }
        guard let importer else { return completion(failure("this engine can't take Chromium logins")) }
        var answered = false
        let finish: (CredentialImport.EngineResult) -> Void = { r in
            guard !answered else { return }
            answered = true
            completion(r)
        }
        profiles.whenLoaded(profileID, { engineProfile in
            // The engine's dictionary form (PROFILE-SERVICES.md). Built here, dropped when the engine answers.
            let logins: [[String: Any]] = credentials.logins.map {
                ["origin": $0.origin, "signonRealm": $0.signonRealm, "actionURL": $0.actionURL,
                 "username": $0.username, "password": $0.password]
            }
            let cookies: [[String: Any]] = credentials.cookies.map {
                ["host": $0.host, "name": $0.name, "path": $0.path, "value": $0.value,
                 "expiresUTC": NSNumber(value: $0.expiresUTC), "secure": $0.secure, "httpOnly": $0.httpOnly,
                 "sameSite": $0.sameSite, "metadata": $0.metadata]
            }
            importer(logins, cookies, engineProfile) { l, c in
                let error = (l["error"] as? String) ?? (c["error"] as? String)
                // Only what the password store kept and read back counts (engine pass 8: "saved"; an existing login
                // is "skipped" and keeps the stored one). Submission alone is not an import.
                let saved = l["saved"] as? Int ?? 0
                if let error, saved + (c["accepted"] as? Int ?? 0) == 0 {
                    return finish(failure(error))
                }
                var r = CredentialImport.EngineResult(
                    loginsImported: saved, loginsRejected: l["rejected"] as? Int ?? 0, loginsSkipped: l["skipped"] as? Int ?? 0,
                    cookiesImported: c["accepted"] as? Int ?? 0, cookiesRejected: c["rejected"] as? Int ?? 0,
                    error: error)
                r.rows = CredentialImport.rows(logins: credentials.logins, loginResults: l["results"] as? [[String: Any]] ?? [],
                                               cookies: credentials.cookies, cookieResults: c["results"] as? [[String: Any]] ?? [],
                                               profileID: profileID)
                finish(r)
            }
        }, failed: {
            finish(failure("its profile couldn't be loaded"))
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            finish(failure("the engine didn't answer"))
        }
    }
}

enum CredentialImport {
    /// What the engine reported for one profile (PROFILE-SERVICES.md): logins it saved and read back, ones it already
    /// had ("skipped", the stored one kept), and "rejected" rows Chromium doesn't take (app or federated logins,
    /// partitioned or invalid cookies) or couldn't store; with a result for each row.
    struct EngineResult: Equatable {
        var loginsImported = 0
        var loginsRejected = 0
        var loginsSkipped = 0
        var cookiesImported = 0
        var cookiesRejected = 0
        /// Set when the engine couldn't store anything; every row sent counts as failed then.
        var error: String?
        var loginsFailed = 0
        var cookiesFailed = 0
        /// One row per login, and per site for cookies (ResultRow).
        var rows: [ResultRow] = []

        static func failed(_ sent: (logins: Int, cookies: Int), _ why: String) -> EngineResult {
            EngineResult(error: why, loginsFailed: sent.logins, cookiesFailed: sent.cookies)
        }
    }

    /// One line of the per-row results: a login (its site and username) or a site's cookies with the same outcome.
    /// Never a password or a cookie's value.
    struct ResultRow: Equatable, Identifiable {
        enum Kind: String { case login, cookies }
        enum Status: String, CaseIterable { case imported, skipped, failed }
        var kind: Kind
        /// The host ("github.com"), or the origin as Arc stored it when it has none (an app login).
        var site: String
        /// A login's username; empty for cookies.
        var username = ""
        /// How many cookies this line stands for (1 for a login).
        var count = 1
        var status: Status
        /// Why, in words (empty for an import that simply worked).
        var reason = ""
        var profileID = ""
        /// P22: the whole of a profile's saved passwords or cookies (a database that couldn't be read, a profile
        /// folder, the engine's store); `count` is 0, since nobody knows how many rows it held.
        var whole = false

        var id: String { [kind.rawValue, profileID, site, username, status.rawValue, reason, whole ? "whole" : ""].joined(separator: "\u{1f}") }

        static func host(_ origin: String) -> String {
            let h = URL(string: origin)?.host ?? origin.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return h.isEmpty ? origin : (h.hasPrefix(".") ? String(h.dropFirst()) : h)
        }
    }

    /// The engine's per-row results in words. Logins keep their order; cookies are grouped by site and outcome.
    static func rows(logins: [ImportedLogin], loginResults: [[String: Any]], cookies: [ImportedCookie],
                     cookieResults: [[String: Any]], profileID: String) -> [ResultRow] {
        var rows: [ResultRow] = []
        for r in loginResults {
            guard let i = (r["index"] as? NSNumber)?.intValue, logins.indices.contains(i) else { continue }
            let (status, reason) = loginStatus(r["status"] as? String ?? "", reason: r["reason"] as? String ?? "")
            rows.append(ResultRow(kind: .login, site: ResultRow.host(logins[i].origin), username: logins[i].username,
                                  status: status, reason: reason, profileID: profileID))
        }
        var grouped: [String: ResultRow] = [:]
        var order: [String] = []
        for r in cookieResults {
            guard let i = (r["index"] as? NSNumber)?.intValue, cookies.indices.contains(i) else { continue }
            let (status, reason) = cookieStatus(r["status"] as? String ?? "", reason: r["reason"] as? String ?? "")
            let row = ResultRow(kind: .cookies, site: ResultRow.host(cookies[i].host), count: 0, status: status, reason: reason,
                                profileID: profileID)
            if grouped[row.id] == nil { order.append(row.id); grouped[row.id] = row }
            grouped[row.id]?.count += 1
        }
        return rows + order.compactMap { grouped[$0] }
    }

    /// Failures of Airc's own stores, which may pass on another try ("Try again" redoes them).
    static let storeFailures: Set<String> = [
        "Airc's password store wasn't available", "Airc's password store couldn't be read", "Airc's password store didn't keep it",
        "The cookie store wasn't available", "The cookie store couldn't keep it",
    ]

    /// saved → imported; an existing login → skipped; a login Chromium doesn't take (not a web login) → skipped; one the
    /// password store didn't keep → failed. The engine's reasons (PROFILE-SERVICES.md) in plain words.
    static func loginStatus(_ status: String, reason: String) -> (ResultRow.Status, String) {
        switch status {
        case "saved": return (.imported, "")
        case "skipped-duplicate": return (.skipped, "Already saved in this profile")
        case "rejected" where reason.contains("invalid HTTP(S)"): return (.skipped, "Not a website login (an app or other kind)")
        case "rejected" where reason == "store unavailable": return (.failed, "Airc's password store wasn't available")
        case "rejected" where reason.contains("store read failed"): return (.failed, "Airc's password store couldn't be read")
        case "rejected" where reason.contains("did not persist") || reason.contains("readback mismatch"):
            return (.failed, "Airc's password store didn't keep it")
        default: return (.failed, reason.isEmpty ? "Couldn't be stored" : reason.prefix(1).uppercased() + reason.dropFirst())
        }
    }

    /// accepted → imported; refused by Chromium's rules (expired, partitioned, invalid domain, Secure/SameSite) →
    /// skipped, each said precisely; the store being unavailable → failed.
    static func cookieStatus(_ status: String, reason: String) -> (ResultRow.Status, String) {
        if status == "accepted" { return (.imported, "") }
        if reason.contains("store unavailable") { return (.failed, "The cookie store wasn't available") }
        if reason.contains("EXCLUDE_FAILURE_TO_STORE") { return (.failed, "The cookie store couldn't keep it") }
        let rules: [(String, String)] = [
            ("partitioned", "Partitioned (a site's cookie kept only inside one other site's pages): Airc can't import these yet"),
            ("expired", "Already expired in Arc"),
            ("invalid domain", "Not for a valid site address"),
            ("EXCLUDE_INVALID_DOMAIN", "Not for a valid site address"),
            ("EXCLUDE_DOMAIN_MISMATCH", "Not for a valid site address"),
            ("invalid SameSite", "Damaged in Arc (an unknown SameSite value)"),
            ("EXCLUDE_INVALID_PREFIX", "Breaks the rules for __Host- and __Secure- cookies"),
            ("EXCLUDE_SAMESITE_NONE_INSECURE", "SameSite=None without Secure, which Chromium refuses"),
            ("EXCLUDE_SECURE_ONLY", "Secure-only, for an address without HTTPS"),
            ("EXCLUDE_OVERWRITE_SECURE", "Airc already has a Secure cookie of that name for the site"),
            ("EXCLUDE_OVERWRITE_HTTP_ONLY", "Airc already has an HttpOnly cookie of that name for the site"),
            ("EXCLUDE_DISALLOWED_CHARACTER", "Its name or value has characters Chromium refuses"),
            ("EXCEEDS_MAX_SIZE", "Its name or value is longer than Chromium allows"),
            ("EXCLUDE_NO_COOKIE_CONTENT", "Has neither a name nor a value"),
        ]
        if let match = rules.first(where: { reason.contains($0.0) }) { return (.skipped, match.1) }
        return (.skipped, "Refused by Chromium's cookie rules")
    }

    /// Rows that didn't come over at read time (Arc's never-save entries, kinds Airc doesn't take, rows that couldn't
    /// be decrypted).
    static func rows(notes: [ImportedCredentials.RowNote], profileID: String) -> [ResultRow] {
        var rows: [ResultRow] = []
        var cookieIndex: [String: Int] = [:]
        for n in notes {
            let reason = n.reason.prefix(1).uppercased() + n.reason.dropFirst()
            switch n.kind {
            case .login:
                rows.append(ResultRow(kind: .login, site: ResultRow.host(n.site), username: n.username,
                                      status: n.skipped ? .skipped : .failed, reason: reason, profileID: profileID))
            case .cookie:
                let row = ResultRow(kind: .cookies, site: ResultRow.host(n.site), count: 0, status: n.skipped ? .skipped : .failed,
                                    reason: reason, profileID: profileID)
                if let i = cookieIndex[row.id] { rows[i].count += 1 } else { cookieIndex[row.id] = rows.count; rows.append(row); rows[rows.count - 1].count = 1 }
            }
        }
        return rows
    }

    // MARK: Outcome

    /// One Arc profile's saved passwords or its cookies: what an import reads at once, and what "Try again" redoes.
    struct Part: Hashable {
        /// The Arc profile's folder ("Default", "Profile 1").
        var directory: String
        var profileID: String
        var kind: ResultRow.Kind
    }

    /// What the latest attempt at one part gave (P22).
    struct Section: Equatable {
        var part: Part
        var rows: [ResultRow] = []
        /// Why the whole part didn't come over (its database or folder couldn't be read, the store took none of it).
        var wholeFailure: String?
        /// Why another try may get further (nil: it won't, or nothing failed).
        var retryReason: String?
        /// Every encrypted value of the part failed to decrypt: the Keychain's key isn't Arc's. Not retryable.
        var keyMismatch = false
        /// Why things failed, with counts (never a value).
        var problems: [String: Int] = [:]
    }

    /// The honest totals the UI shows, computed from each profile's sections so a retry can replace just what it redid.
    struct Outcome: Equatable {
        /// The import this belongs to; a retry keeps it and counts `attempt` up.
        var runID = UUID()
        var attempt = 1
        var sections: [Section] = []

        var rows: [ResultRow] { sections.flatMap(\.rows) }
        /// Rows by status, counting each cookie.
        func count(_ status: ResultRow.Status) -> Int { rows.filter { $0.status == status }.reduce(0) { $0 + $1.count } }
        var loginsImported: Int { rows.filter { $0.kind == .login && $0.status == .imported }.reduce(0) { $0 + $1.count } }
        var cookiesImported: Int { rows.filter { $0.kind == .cookies && $0.status == .imported }.reduce(0) { $0 + $1.count } }
        /// Arc's "never save" entries, kinds Airc doesn't take, and rows Chromium refuses.
        var skipped: Int { count(.skipped) }
        /// Rows that couldn't be read, decrypted or stored.
        var failed: Int { count(.failed) }
        /// Airc profile IDs none of whose parts came over (the folder, both databases, or the engine's store failed).
        var failedProfiles: [String] {
            var out: [String] = []
            for s in sections where !out.contains(s.part.profileID) {
                let mine = sections.filter { $0.part.profileID == s.part.profileID }
                if mine.allSatisfy({ $0.wholeFailure != nil }) { out.append(s.part.profileID) }
            }
            return out
        }
        var profiles: Int { Set(sections.map(\.part.profileID)).count }
        var problems: [String: Int] { sections.reduce(into: [:]) { acc, s in for (k, v) in s.problems { acc[k, default: 0] += v } } }
        /// What "Try again" redoes.
        var retryable: [Part] { sections.filter { $0.retryReason != nil }.map(\.part) }
        var keyMismatchProfiles: [String] {
            sections.filter(\.keyMismatch).map(\.part.profileID).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        }

        /// Nothing came over and something went wrong: shown as a failure, never as "ready".
        var isFailure: Bool {
            loginsImported + cookiesImported == 0 && (failed > 0 || sections.contains { $0.wholeFailure != nil })
        }

        /// What didn't come over, grouped by reason, most first: "3 cookies · Partitioned (…)".
        var notImported: [(kind: ResultRow.Kind, status: ResultRow.Status, reason: String, count: Int)] {
            var groups: [String: (kind: ResultRow.Kind, status: ResultRow.Status, reason: String, count: Int)] = [:]
            var order: [String] = []
            for r in rows where r.status != .imported && !r.whole {
                let key = r.kind.rawValue + "\u{1f}" + r.status.rawValue + "\u{1f}" + r.reason
                if groups[key] == nil { order.append(key); groups[key] = (r.kind, r.status, r.reason, 0) }
                groups[key]?.count += r.count
            }
            return order.compactMap { groups[$0] }.sorted { $0.count > $1.count }
        }

        var summary: String {
            var parts = ["\(loginsImported.formatted()) \(loginsImported == 1 ? "login" : "logins") and "
                         + "\(cookiesImported.formatted()) \(cookiesImported == 1 ? "cookie" : "cookies") imported."]
            if skipped > 0 { parts.append("\(skipped.formatted()) skipped.") }
            if failed > 0 { parts.append("\(failed.formatted()) couldn't be read.") }
            let failedProfiles = failedProfiles
            if !failedProfiles.isEmpty {
                parts.append(failedProfiles.count == 1 ? "One profile couldn't be read." : "\(failedProfiles.count) profiles couldn't be read.")
            }
            // A part that failed whole in a profile that otherwise came over.
            for kind in [ResultRow.Kind.login, .cookies] {
                let n = Set(sections.filter { $0.part.kind == kind && $0.wholeFailure != nil && !failedProfiles.contains($0.part.profileID) }
                    .map(\.part.profileID)).count
                guard n > 0 else { continue }
                let what = kind == .login ? "saved passwords" : "cookies"
                parts.append(n == 1 ? "One profile's \(what) couldn't be read." : "\(n) profiles' \(what) couldn't be read.")
            }
            let mismatch = keyMismatchProfiles.count
            if mismatch > 0 {
                parts.append((mismatch == 1 ? "One profile's" : "\(mismatch) profiles'")
                             + " logins didn't open with the key in “Arc Safe Storage”; it may have changed since Arc saved them.")
            }
            return parts.joined(separator: " ")
        }

        /// This outcome with `fresh` in place of the sections of the same parts (a retry).
        func replacing(_ fresh: [Section]) -> Outcome {
            var next = self
            next.attempt += 1
            for s in fresh {
                if let i = next.sections.firstIndex(where: { $0.part == s.part }) {
                    // A login an earlier attempt saved comes back "Already saved": it stays imported.
                    let saved = Set(next.sections[i].rows.filter { $0.kind == .login && $0.status == .imported }.map { $0.site + "\u{1f}" + $0.username })
                    var merged = s
                    merged.rows = s.rows.map { r in
                        guard r.kind == .login, r.status == .skipped, r.reason == "Already saved in this profile",
                              saved.contains(r.site + "\u{1f}" + r.username) else { return r }
                        var kept = r; kept.status = .imported; kept.reason = ""; return kept
                    }
                    next.sections[i] = merged
                } else {
                    next.sections.append(s)
                }
            }
            return next
        }
    }

    /// One profile's read and the engine's answer as sections, one per kind read (`kinds`).
    static func sections(directory: String, profileID: String, kinds: [ResultRow.Kind], read c: ImportedCredentials,
                         engine r: EngineResult?) -> [Section] {
        let notes = rows(notes: c.notes, profileID: profileID)
        return kinds.map { kind in
            var s = Section(part: Part(directory: directory, profileID: profileID, kind: kind))
            let database = kind == .login ? "Login Data" : "Cookies"
            s.rows = notes.filter { $0.kind == kind } + (r?.rows.filter { $0.kind == kind } ?? [])
            for (k, v) in c.problems where k.hasPrefix(kind == .login ? "login" : "cookie") || k.hasPrefix(database) { s.problems[k, default: 0] += v }
            if c.failedDatabases.contains(database) {
                let why = c.databaseReasons[database] ?? "It couldn't be read."
                s.wholeFailure = why
                s.retryReason = why
                s.rows.insert(ResultRow(kind: kind, site: kind == .login ? "All saved passwords" : "All cookies", count: 0,
                                        status: .failed, reason: "Arc's " + (kind == .login ? "password" : "cookie") + " database: " + why,
                                        profileID: profileID, whole: true), at: 0)
            }
            if let r, let error = r.error {
                s.problems["engine: " + error, default: 0] += 1
                let sent = kind == .login ? r.loginsFailed : r.cookiesFailed
                if r.loginsImported + r.cookiesImported == 0, sent > 0 {
                    s.wholeFailure = "Airc couldn't store them: " + error
                    s.retryReason = s.wholeFailure
                }
            }
            if s.retryReason == nil, s.rows.contains(where: { $0.status == .failed && storeFailures.contains($0.reason) }) {
                s.retryReason = "Airc's store didn't keep some of them"
            }
            // A wrong key: every encrypted value failed (logins and cookies share the key, so both parts say so).
            s.keyMismatch = c.keyMismatch && s.rows.contains { $0.status == .failed && !$0.whole }
            return s
        }
    }

    /// A profile folder that couldn't be read at all: every kind asked for failed whole, and may on another try.
    static func unreadable(directory: String, profileID: String, kinds: [ResultRow.Kind], error: Error) -> [Section] {
        let why: String
        if let e = error as? ImportError, e == .permissionDenied { why = "macOS didn't let Airc read Arc's profile folder." }
        else { why = "Arc's profile folder couldn't be read." }
        return kinds.map { kind in
            Section(part: Part(directory: directory, profileID: profileID, kind: kind),
                    rows: [ResultRow(kind: kind, site: kind == .login ? "All saved passwords" : "All cookies", count: 0, status: .failed,
                                     reason: why, profileID: profileID, whole: true)],
                    wholeFailure: why, retryReason: why,
                    problems: ["profile: " + ((error as? LocalizedError)?.errorDescription ?? "\(error)"): 1])
        }
    }

    /// The import didn't start because the engine can't take Chromium logins (WebKit). Nothing was read.
    struct Unsupported: LocalizedError {
        var errorDescription: String? { "Logins come over with the Chromium engine. This build runs on WebKit, so nothing was read." }
    }

    // MARK: Session and retry

    /// How the key is got: the Keychain item "Arc Safe Storage" (macOS asks), or a synthetic key in checks.
    typealias KeySource = @Sendable () throws -> Data

    /// The last Arc login import (P22), kept so "Try again" can redo only what failed. It holds no credential and no
    /// key: Arc's folder, which Arc profile goes into which Airc profile, where they go, and how the key is asked for
    /// (macOS may ask again on a retry).
    final class Session: ObservableObject {
        static let shared = Session()
        @Published fileprivate(set) var outcome: Outcome?
        @Published fileprivate(set) var retrying = false
        fileprivate var arcDirectory: URL?
        fileprivate weak var sink: CredentialSink?
        fileprivate var keySource: KeySource?
        fileprivate var progress: ((Double) -> Void)?
        fileprivate var completion: ((Result<Outcome, Error>) -> Void)?

        var canRetry: Bool { !retrying && outcome?.retryable.isEmpty == false && arcDirectory != nil && sink != nil && keySource != nil }
    }

    /// The last finished import's totals (counts and per-row results, never a value), for Settings → Import.
    static var lastOutcome: Outcome? { Session.shared.outcome }

    /// Asks macOS for "Arc Safe Storage" (the system password prompt), then reads every mapped profile's logins and
    /// cookies off the main thread, from private copies (Arc may be running), and hands each profile's to `sink`
    /// before reading the next. `profiles` maps Arc profile directories to Airc profile IDs.
    static func run(arcDirectory: URL, profiles: [(directory: String, profileID: String)], sink: CredentialSink,
                    progress: @escaping (Double) -> Void, completion: @escaping (Result<Outcome, Error>) -> Void) {
        precondition(!LaunchOptions.current.isAutomated, "credentials are never read in automated runs")
        start(arcDirectory: arcDirectory, profiles: profiles, sink: sink,
              keySource: { try ArcSafeStorage.deriveKey(password: ArcSafeStorage.readPassword()) },
              progress: progress, completion: completion)
    }

    #if AIRC_TESTING
    /// The synthetic checks (CredentialCheck.swift, ImportAcceptanceCheck.swift): `key` replaces the Keychain read.
    static func run(arcDirectory: URL, profiles: [(directory: String, profileID: String)], sink: CredentialSink,
                    key: Data?, progress: @escaping (Double) -> Void,
                    completion: @escaping (Result<Outcome, Error>) -> Void) {
        guard let key else { return run(arcDirectory: arcDirectory, profiles: profiles, sink: sink, progress: progress, completion: completion) }
        start(arcDirectory: arcDirectory, profiles: profiles, sink: sink, keySource: { key }, progress: progress, completion: completion)
    }

    /// The Keychain's answer simulated (ImportAcceptanceCheck): `status` goes through the real lookup's handling, and a
    /// success gives the synthetic password `password`. Never the real Keychain.
    static func run(arcDirectory: URL, profiles: [(directory: String, profileID: String)], sink: CredentialSink,
                    keychainStatus: @escaping @Sendable () -> OSStatus, password: Data, progress: @escaping (Double) -> Void,
                    completion: @escaping (Result<Outcome, Error>) -> Void) {
        start(arcDirectory: arcDirectory, profiles: profiles, sink: sink, keySource: {
            let status = keychainStatus()
            return try ArcSafeStorage.deriveKey(password: ArcSafeStorage.readPassword { _, result in
                if status == errSecSuccess { result?.pointee = password as CFData }
                return status
            })
        }, progress: progress, completion: completion)
    }
    #endif

    private static func start(arcDirectory: URL, profiles: [(directory: String, profileID: String)], sink: CredentialSink,
                              keySource: @escaping KeySource, progress: @escaping (Double) -> Void,
                              completion: @escaping (Result<Outcome, Error>) -> Void) {
        guard sink.acceptsCredentials else { return completion(.failure(Unsupported())) }
        let session = Session.shared
        session.arcDirectory = arcDirectory
        session.sink = sink
        session.keySource = keySource
        session.progress = progress
        session.completion = completion
        let parts = profiles.flatMap { p in [ResultRow.Kind.login, .cookies].map { Part(directory: p.directory, profileID: p.profileID, kind: $0) } }
        read(parts, previous: nil)
    }

    /// Reads only what the last import couldn't bring and couldn't store, with the same profiles, sink and key source,
    /// and hands the merged outcome to the same callbacks. False when there's nothing to retry.
    @discardableResult
    static func retry() -> Bool {
        let session = Session.shared
        guard session.canRetry, let previous = session.outcome else { return false }
        session.retrying = true
        read(previous.retryable, previous: previous)
        return true
    }

    private static func read(_ parts: [Part], previous: Outcome?) {
        let session = Session.shared
        guard let arcDirectory = session.arcDirectory, let sink = session.sink, let keySource = session.keySource else { return }
        let progress = session.progress, completion = session.completion
        // Profile by profile, in the order given, each with the kinds asked for.
        var order: [String] = []
        var kinds: [String: (directory: String, kinds: [ResultRow.Kind])] = [:]
        for p in parts {
            if kinds[p.profileID] == nil { order.append(p.profileID); kinds[p.profileID] = (p.directory, []) }
            if !kinds[p.profileID]!.kinds.contains(p.kind) { kinds[p.profileID]!.kinds.append(p.kind) }
        }
        let plan = order.map { (directory: kinds[$0]!.directory, profileID: $0, kinds: kinds[$0]!.kinds) }
        Task.detached(priority: .userInitiated) {
            do {
                let key = try keySource()
                var fresh: [Section] = []
                for (i, p) in plan.enumerated() {
                    let dir = arcDirectory.appendingPathComponent("User Data").appendingPathComponent(p.directory)
                    do {
                        let creds = try await ArcCredentialImporter.read(profileDirectory: dir, key: key,
                                                                         includeLogins: p.kinds.contains(.login),
                                                                         includeCookies: p.kinds.contains(.cookies))
                        var engine: EngineResult?
                        if !(creds.logins.isEmpty && creds.cookies.isEmpty) {
                            engine = await withCheckedContinuation { (cont: CheckedContinuation<EngineResult, Never>) in
                                Task { @MainActor in sink.receive(creds, forProfile: p.profileID) { cont.resume(returning: $0) } }
                            }
                        }
                        fresh += sections(directory: p.directory, profileID: p.profileID, kinds: p.kinds, read: creds, engine: engine)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        fresh += unreadable(directory: p.directory, profileID: p.profileID, kinds: p.kinds, error: error)
                    }
                    let done = Double(i + 1) / Double(max(1, plan.count))
                    await MainActor.run { progress?(done) }
                }
                let result = previous?.replacing(fresh) ?? Outcome(sections: fresh)
                await MainActor.run {
                    session.outcome = result
                    session.retrying = false
                    completion?(.success(result))
                }
            } catch {
                await MainActor.run {
                    session.retrying = false
                    completion?(.failure(error))
                }
            }
        }
    }
}

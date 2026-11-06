// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircImport
import AircKit
import Foundation

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

        var id: String { [kind.rawValue, profileID, site, username, status.rawValue, reason].joined(separator: "\u{1f}") }

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

    /// saved → imported; an existing login → skipped; a login Chromium doesn't take (not a web login) → skipped; one the
    /// password store didn't keep → failed.
    static func loginStatus(_ status: String, reason: String) -> (ResultRow.Status, String) {
        switch status {
        case "saved": return (.imported, "")
        case "skipped-duplicate": return (.skipped, "Already saved in this profile")
        case "rejected" where reason.contains("invalid HTTP(S)"): return (.skipped, "Not a website login (an app or other kind)")
        default: return (.failed, reason.isEmpty ? "Couldn't be stored" : reason.prefix(1).uppercased() + reason.dropFirst())
        }
    }

    /// accepted → imported; refused by Chromium's rules (expired, partitioned, invalid domain, Secure/SameSite) →
    /// skipped; the store being unavailable → failed.
    static func cookieStatus(_ status: String, reason: String) -> (ResultRow.Status, String) {
        if status == "accepted" { return (.imported, "") }
        if reason.contains("store unavailable") { return (.failed, "The cookie store wasn't available") }
        return (.skipped, reason.isEmpty ? "Refused by the browser's cookie rules" : reason.prefix(1).uppercased() + reason.dropFirst())
    }

    /// Rows that didn't come over at read time (Arc's never-save entries, rows that couldn't be decrypted).
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

    /// The honest totals the UI shows.
    struct Outcome: Equatable {
        var loginsImported = 0
        var cookiesImported = 0
        /// Arc's "never save" entries, and rows Chromium doesn't take.
        var skipped = 0
        /// Rows that couldn't be read, decrypted or stored.
        var failed = 0
        /// Airc profile IDs whose Arc data couldn't be read at all, or that the engine couldn't store into.
        var failedProfiles: [String] = []
        var profiles = 0
        /// Why things failed, with counts (never a value).
        var problems: [String: Int] = [:]
        /// Every login and every site's cookies with what happened to them (Settings → Import, the onboarding's Logins).
        var rows: [ResultRow] = []
        /// Rows by status, counting each cookie.
        func count(_ status: ResultRow.Status) -> Int { rows.filter { $0.status == status }.reduce(0) { $0 + $1.count } }

        /// Nothing came over and something went wrong: shown as a failure, never as "ready".
        var isFailure: Bool { loginsImported + cookiesImported == 0 && (failed > 0 || !failedProfiles.isEmpty) }

        var summary: String {
            var parts = ["\(loginsImported.formatted()) \(loginsImported == 1 ? "login" : "logins") and "
                         + "\(cookiesImported.formatted()) \(cookiesImported == 1 ? "cookie" : "cookies") imported."]
            if skipped > 0 { parts.append("\(skipped.formatted()) skipped.") }
            if failed > 0 { parts.append("\(failed.formatted()) couldn't be read.") }
            if !failedProfiles.isEmpty {
                parts.append(failedProfiles.count == 1 ? "One profile couldn't be read." : "\(failedProfiles.count) profiles couldn't be read.")
            }
            return parts.joined(separator: " ")
        }

        mutating func add(read c: ImportedCredentials, profileID: String = "") {
            skipped += c.skippedLogins
            failed += c.failedLogins + c.failedCookies
            for (k, v) in c.problems { problems[k, default: 0] += v }
            rows += CredentialImport.rows(notes: c.notes, profileID: profileID)
        }

        mutating func add(engine r: EngineResult, profileID: String) {
            loginsImported += r.loginsImported
            cookiesImported += r.cookiesImported
            skipped += r.loginsSkipped + r.loginsRejected + r.cookiesRejected
            rows += r.rows
            failed += r.loginsFailed + r.cookiesFailed
            if let e = r.error {
                problems["engine: " + e, default: 0] += 1
                if r.loginsImported + r.cookiesImported == 0, !failedProfiles.contains(profileID) { failedProfiles.append(profileID) }
            }
        }
    }

    /// The import didn't start because the engine can't take Chromium logins (WebKit). Nothing was read.
    struct Unsupported: LocalizedError {
        var errorDescription: String? { "Logins come over with the Chromium engine. This build runs on WebKit, so nothing was read." }
    }

    /// The last finished import's totals (counts only), for Settings → Import.
    static var lastOutcome: Outcome?

    /// Asks macOS for "Arc Safe Storage" (the system password prompt), then reads every mapped profile's logins and
    /// cookies off the main thread, from private copies (Arc may be running), and hands each profile's to `sink`
    /// before reading the next. `profiles` maps Arc profile directories to Airc profile IDs.
    static func run(arcDirectory: URL, profiles: [(directory: String, profileID: String)], sink: CredentialSink,
                    progress: @escaping (Double) -> Void, completion: @escaping (Result<Outcome, Error>) -> Void) {
        read(arcDirectory: arcDirectory, profiles: profiles, sink: sink, key: nil, progress: progress, completion: completion)
    }

    #if AIRC_TESTING
    /// The synthetic check (CredentialCheck.swift): `key` replaces the Keychain read.
    static func run(arcDirectory: URL, profiles: [(directory: String, profileID: String)], sink: CredentialSink,
                    key: Data?, progress: @escaping (Double) -> Void,
                    completion: @escaping (Result<Outcome, Error>) -> Void) {
        read(arcDirectory: arcDirectory, profiles: profiles, sink: sink, key: key, progress: progress, completion: completion)
    }
    #endif

    private static func read(arcDirectory: URL, profiles: [(directory: String, profileID: String)], sink: CredentialSink,
                             key: Data?, progress: @escaping (Double) -> Void,
                             completion: @escaping (Result<Outcome, Error>) -> Void) {
        guard sink.acceptsCredentials else { return completion(.failure(Unsupported())) }
        precondition(key != nil || !LaunchOptions.current.isAutomated, "credentials are never read in automated runs")
        Task.detached(priority: .userInitiated) {
            do {
                let key = try key ?? ArcSafeStorage.deriveKey(password: ArcSafeStorage.readPassword())
                var outcome = Outcome()
                for (i, p) in profiles.enumerated() {
                    let dir = arcDirectory.appendingPathComponent("User Data").appendingPathComponent(p.directory)
                    do {
                        let creds = try await ArcCredentialImporter.read(profileDirectory: dir, key: key)
                        outcome.add(read: creds, profileID: p.profileID)
                        if creds.logins.isEmpty && creds.cookies.isEmpty {
                            if !creds.failedDatabases.isEmpty { outcome.failedProfiles.append(p.profileID) }
                        } else {
                            let r = await withCheckedContinuation { (cont: CheckedContinuation<EngineResult, Never>) in
                                Task { @MainActor in sink.receive(creds, forProfile: p.profileID) { cont.resume(returning: $0) } }
                            }
                            outcome.add(engine: r, profileID: p.profileID)
                        }
                        outcome.profiles += 1
                    } catch {
                        outcome.failedProfiles.append(p.profileID)
                        outcome.problems["profile: " + ((error as? LocalizedError)?.errorDescription ?? "\(error)"), default: 0] += 1
                    }
                    let done = Double(i + 1) / Double(max(1, profiles.count))
                    await MainActor.run { progress(done) }
                }
                let result = outcome
                await MainActor.run {
                    lastOutcome = result
                    completion(.success(result))
                }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }
}

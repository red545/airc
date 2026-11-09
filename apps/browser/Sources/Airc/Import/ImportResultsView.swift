// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import SwiftUI

/// The per-row results of a login import (engine pass 8): every login with its site and username, and every site's
/// cookies, each imported, skipped or failed, with why. Problems first. Shown under the onboarding's Logins step and
/// in Settings → Import. Never a password or a cookie's value.
/// P22: what didn't come over, grouped by reason, above the rows; a whole database or profile that couldn't be read as
/// one row; and **Try Again**, which redoes only the parts that failed and may pass on another try (a database Arc was
/// writing, a store that didn't answer), keeping everything that came over.
struct ImportResultsView: View {
    typealias Row = CredentialImport.ResultRow
    let outcome: CredentialImport.Outcome
    /// Profile ID → name, shown on each row while the import covered several profiles.
    var profileNames: [String: String] = [:]
    var maxHeight: CGFloat = 220
    @State private var filter: Row.Status?
    @ObservedObject private var session = CredentialImport.Session.shared
    @Environment(\.aircTheme) private var theme

    /// The newest outcome of this import: a retry (from here or elsewhere) replaces the one passed in.
    private var shown: CredentialImport.Outcome {
        if let s = session.outcome, s.runID == outcome.runID, s.attempt > outcome.attempt { return s }
        return outcome
    }

    private var showsProfiles: Bool { Set(shown.rows.map(\.profileID)).count > 1 }

    /// Failed, then skipped, then imported; the import's own order within each.
    private var visible: [Row] {
        let order: [Row.Status] = [.failed, .skipped, .imported]
        let rows = shown.rows
        return order.filter { filter == nil || filter == $0 }.flatMap { s in rows.filter { $0.status == s } }
    }

    /// What a chip counts: each login and cookie, and a whole database or profile as one (it has no row count).
    private func items(_ status: Row.Status) -> Int {
        shown.count(status) + shown.rows.filter { $0.whole && $0.status == status }.count
    }

    /// Try Again belongs to the import the session still holds.
    private var canRetry: Bool { session.outcome?.runID == shown.runID && !shown.retryable.isEmpty && (session.canRetry || session.retrying) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                chip(nil, "All", count: nil)
                chip(.imported, "Imported", count: items(.imported))
                chip(.skipped, "Skipped", count: items(.skipped))
                chip(.failed, "Failed", count: items(.failed))
                Spacer(minLength: 0)
                if canRetry { retryButton }
            }
            let reasons = shown.notImported
            if !reasons.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(0..<min(4, reasons.count), id: \.self) { i in
                        reasonLine(status: reasons[i].status, kind: reasons[i].kind, reason: reasons[i].reason, count: reasons[i].count)
                    }
                    if reasons.count > 4 {
                        Text("And \(reasons.count - 4) more \(reasons.count == 5 ? "reason" : "reasons") below.")
                            .aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextTertiary.color)
                    }
                }
                .testAnchor("results.reasons")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if visible.isEmpty {
                        Text(filter == nil ? "Nothing was read." : "None.")
                            .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextTertiary.color)
                            .padding(10)
                    }
                    ForEach(visible) { row($0) }
                }
            }
            .frame(maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: visible.count < 5)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.fieldFill.color))
        }
    }

    private var retryButton: some View {
        let profiles = Set(shown.retryable.map(\.profileID)).count
        return Button {
            CredentialImport.retry()
        } label: {
            HStack(spacing: 5) {
                if session.retrying { ProgressView().controlSize(.mini) }
                Text(session.retrying ? "Trying Again…" : (profiles == 1 ? "Try Again" : "Try Again for \(profiles) Profiles"))
            }
        }
        .buttonStyle(.airc(.secondary, size: .small))
        .disabled(session.retrying)
        .testAnchor("results.retry")
    }

    private func reasonLine(status: Row.Status, kind: Row.Kind, reason: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            icon(status).font(.system(size: 10, weight: .semibold)).frame(width: 14)
            (Text("\(count.formatted()) " + noun(kind, count)).fontWeight(.semibold) + Text(" · " + reason))
                .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func noun(_ kind: Row.Kind, _ n: Int) -> String {
        kind == .login ? (n == 1 ? "login" : "logins") : (n == 1 ? "cookie" : "cookies")
    }

    private func chip(_ status: Row.Status?, _ title: String, count: Int?) -> some View {
        let on = filter == status
        return Button { filter = status } label: {
            HStack(spacing: 4) {
                Text(title)
                if let count { Text(count.formatted()).monospacedDigit().opacity(0.7) }
            }
            .aircFont(AircFont.callout.weight(.medium))
            .foregroundStyle((on ? theme.surfaceText : theme.surfaceTextSecondary).color)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(on ? theme.surfaceSelected.color : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .testAnchor("results." + (status?.rawValue ?? "all"))
    }

    private func row(_ r: Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon(r.status).font(.system(size: 11, weight: .semibold)).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(r.site).aircFont(AircFont.body).foregroundStyle(theme.surfaceText.color).lineLimit(1)
                    Text(r.whole ? "the whole profile"
                         : r.kind == .login ? (r.username.isEmpty ? "no username" : r.username)
                         : (r.count == 1 ? "1 cookie" : "\(r.count.formatted()) cookies"))
                        .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color).lineLimit(1)
                    Spacer(minLength: 0)
                    if showsProfiles || r.whole, let name = profileNames[r.profileID] {
                        Text(name).aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextTertiary.color).lineLimit(1)
                    }
                }
                if !r.reason.isEmpty {
                    Text(r.reason).aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextTertiary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func icon(_ s: Row.Status) -> some View {
        switch s {
        case .imported: Image(systemName: "checkmark.circle.fill").foregroundStyle(AircColor(0x2F9E62).color)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(theme.surfaceTextTertiary.color)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(AircColor(0xE0892B).color)
        }
    }
}

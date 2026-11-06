// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import SwiftUI

/// The per-row results of a login import (engine pass 8): every login with its site and username, and every site's
/// cookies, each imported, skipped or failed, with why. Problems first. Shown under the onboarding's Logins step and
/// in Settings → Import. Never a password or a cookie's value.
struct ImportResultsView: View {
    typealias Row = CredentialImport.ResultRow
    let outcome: CredentialImport.Outcome
    /// Profile ID → name, shown on each row while the import covered several profiles.
    var profileNames: [String: String] = [:]
    var maxHeight: CGFloat = 220
    @State private var filter: Row.Status?
    @Environment(\.aircTheme) private var theme

    private var showsProfiles: Bool { Set(outcome.rows.map(\.profileID)).count > 1 }

    /// Failed, then skipped, then imported; the import's own order within each.
    private var visible: [Row] {
        let order: [Row.Status] = [.failed, .skipped, .imported]
        return order.filter { filter == nil || filter == $0 }.flatMap { s in outcome.rows.filter { $0.status == s } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                chip(nil, "All", count: nil)
                chip(.imported, "Imported", count: outcome.count(.imported))
                chip(.skipped, "Skipped", count: outcome.count(.skipped))
                chip(.failed, "Failed", count: outcome.count(.failed))
                Spacer(minLength: 0)
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
                    Text(r.kind == .login ? (r.username.isEmpty ? "no username" : r.username)
                                         : (r.count == 1 ? "1 cookie" : "\(r.count.formatted()) cookies"))
                        .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color).lineLimit(1)
                    Spacer(minLength: 0)
                    if showsProfiles, let name = profileNames[r.profileID] {
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

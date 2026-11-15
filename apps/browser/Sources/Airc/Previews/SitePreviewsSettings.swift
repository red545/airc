// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import SwiftUI

/// Settings → Appearance → Site Previews (S04), Arc's per-site preview switches ("Gmail: Unread emails"). A site that's
/// off keeps the page-picture card, its row loses "3 Recent", and nothing of it is read.
struct SitePreviewsSettingsSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsSection(title: "Site Previews",
                        help: "Rest the pointer on a pinned tab or Favorite of these sites to see what's there. Mail and calendars come from the site's own page, signed in, in that profile; nothing is sent anywhere else.") {
            ForEach(PreviewService.allCases, id: \.self) { s in
                AircToggleRow(s.name, subtitle: s.settingsDetail, isOn: Binding(
                    get: { !model.settings.values.servicePreviewsOff.contains(s.rawValue) },
                    set: { on in Self.set(s, on: on, in: model.settings) }))
            }
        }
    }

    static func set(_ s: PreviewService, on: Bool, in settings: AppSettings) {
        var off = settings.values.servicePreviewsOff.filter { $0 != s.rawValue }
        if !on { off.append(s.rawValue) }
        settings.values.servicePreviewsOff = off.sorted()
        ServicePreviewCenter.shared.enabledChanged()
    }
}

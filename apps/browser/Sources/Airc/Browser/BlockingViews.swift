// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI
import AircDesign
import AircKit

/// Profile controls live here; the shared Settings pane only registers this group.
struct BlockingProfileRows: View {
    @ObservedObject var center: BlockingCenter
    let profile: String
    @State private var listsOpen = false
    @State private var sitesOpen = false
    @State private var downloading = false
    @State private var problem: String?
    private var config: BlockingProfileConfiguration { center.settings.configuration(profile) }
    var body: some View {
        AircToggleRow("Block ads and trackers", subtitle: "Built-in protection with EasyList and EasyPrivacy.",
            isOn: Binding(get: { config.enabled }, set: { center.settings.setEnabled($0, profile: profile) }))
        AircToggleRow("Block cookie banners", subtitle: "Downloads an optional list. Some pages may load incorrectly.",
            isOn: Binding(get: { config.selectedLists.contains("cookies") }, set: { value in
                downloading = true
                Task { @MainActor in
                    if !(await center.setList("cookies", selected: value, profile: profile)) { problem = "The cookie list couldn’t be downloaded. Try again later." }
                    downloading = false
                }
            })).disabled(downloading)
        SettingsRow(title: "Lists", subtitle: "Updates contact the list authors and show them your IP address.") {
            Button("Lists…") { listsOpen = true }.buttonStyle(.airc(.secondary))
        }.sheet(isPresented: $listsOpen) { BlockingListsView(center: center, profile: profile) }
        SettingsRow(title: "Sites where blocking is off", subtitle: config.exceptions.isEmpty ? "No exceptions" : "\(config.exceptions.count) sites") {
            Button("Manage…") { sitesOpen = true }.buttonStyle(.airc(.secondary))
        }.sheet(isPresented: $sitesOpen) { BlockingSitesView(center: center, profile: profile) }
        AircToggleRow("Block third-party cookies", subtitle: "Some sign-ins and embedded pages may stop working. Private browsing and Safari’s engine keep their own cookie protections.",
            isOn: Binding(get: { config.blockThirdPartyCookies }, set: { value in center.settings.update(profile) { $0.blockThirdPartyCookies = value } }))
        if center.settings.shouldOfferCoexistence(profile: profile, extensionIDs: center.blockers(profile: profile).map(\.id)) {
            BlockingOfferCard(center: center, profile: profile).padding(14)
        }
        if let error = problem ?? center.failures[profile] ?? center.settings.error {
            Text(error).aircFont(AircFont.callout).foregroundStyle(AircColor.destructive.color).padding(14)
        }
    }
}

private struct BlockingListsView: View {
    @ObservedObject var center: BlockingCenter
    @ObservedObject private var lists: BlockingListStore
    let profile: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.aircTheme) private var theme
    @State private var pending: Set<String> = []
    @State private var problem: String?
    init(center: BlockingCenter, profile: String) { self.center = center; self.lists = center.lists; self.profile = profile }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Blocking Lists").aircFont(AircFont.title2); Spacer(); Button("Done") { dismiss() }.buttonStyle(.airc(.secondary)) }
            Text("Lists update from their authors every four days, or later when a list asks us to wait. These requests show the list hosts your IP address.")
                .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
            AircGroup {
                ForEach(BlockingListDescriptor.catalog) { list in
                    VStack(alignment: .leading, spacing: 0) {
                        AircToggleRow(list.title, subtitle: subtitle(list), isOn: Binding(
                            get: { center.settings.configuration(profile).selectedLists.contains(list.id) },
                            set: { value in
                                pending.insert(list.id)
                                Task { @MainActor in
                                    if !(await center.setList(list.id, selected: value, profile: profile)) { problem = "Couldn’t download \(list.title). Your current lists are unchanged." }
                                    pending.remove(list.id)
                                }
                            })).disabled(pending.contains(list.id) || lists.updating.contains(list.id))
                        if let error = lists.errors[list.id] { Text(error).aircFont(AircFont.caption).padding(.horizontal, 14).padding(.bottom, 8) }
                    }
                }
            }
            HStack {
                Button(lists.updating.isEmpty ? "Update Now" : "Updating…") { Task { await center.refresh(force: true) } }
                    .buttonStyle(.airc(.secondary)).disabled(!lists.updating.isEmpty)
                Spacer()
                Link("The EasyList authors", destination: URL(string: "https://easylist.to/")!).aircFont(AircFont.callout)
            }
            Text("Bundled EasyList and EasyPrivacy © The EasyList authors, CC BY-SA 3.0 or later. Source lists, converted rules and attribution are included with Airc. Optional lists download directly from their authors; no blocker extension is bundled.")
                .aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextSecondary.color)
            if let problem { Text(problem).aircFont(AircFont.callout).foregroundStyle(AircColor.destructive.color) }
        }.padding(24).frame(width: 520).foregroundStyle(theme.surfaceText.color).background(theme.surface.color)
    }
    private func subtitle(_ list: BlockingListDescriptor) -> String {
        let version = lists.versions[list.id]?.metadata.version ?? "Not downloaded"
        return "\(list.category) · \(version) · \(list.url.host ?? "")\n\(list.license)"
    }
}

private struct BlockingSitesView: View {
    @ObservedObject var center: BlockingCenter
    let profile: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.aircTheme) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Sites Where Blocking Is Off").aircFont(AircFont.title2); Spacer(); Button("Done") { dismiss() }.buttonStyle(.airc(.secondary)) }
            let sites = center.settings.configuration(profile).exceptions.sorted()
            if sites.isEmpty { Text("Blocking follows this profile’s setting on every site.").aircFont(AircFont.callout) }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(sites, id: \.self) { host in
                        HStack {
                            Text(host).aircFont(AircFont.body).textSelection(.enabled)
                            Spacer()
                            Button("Remove") { center.settings.removeException(host, profile: profile) }.buttonStyle(.airc(.secondary))
                        }.padding(8)
                    }
                }
            }.frame(maxHeight: 300)
            Text("Changes apply when a page reloads. Private-window exceptions are temporary and don’t appear here.")
                .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
        }.padding(24).frame(width: 480).foregroundStyle(theme.surfaceText.color).background(theme.surface.color)
    }
}

struct BlockingSiteRow: View {
    @ObservedObject var center: BlockingCenter
    let page: EngineTab
    @Environment(\.aircTheme) private var theme
    @State private var applying = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "shield.lefthalf.filled").frame(width: 18)
                Text("Block Ads & Trackers").aircFont(AircFont.body)
                Spacer(minLength: 4)
                AircSwitch(isOn: Binding(get: { center.enabled(for: page) }, set: { value in
                    applying = true; center.setSiteEnabled(value, tab: page) { applying = false }
                })).disabled(applying || !center.profileEnabled(for: page)).accessibilityLabel("Block ads and trackers for this site")
            }
            Text(subtitle).aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextSecondary.color).fixedSize(horizontal: false, vertical: true)
            if center.enabled(for: page) {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    if let count = center.count(for: page) { Text("\(count) blocked on this page").aircFont(AircFont.mono).foregroundStyle(theme.surfaceTextSecondary.color) }
                }
            }
        }.foregroundStyle(theme.surfaceText.color).padding(.horizontal, AircSpacing.m).padding(.vertical, 10)
    }
    private var subtitle: String {
        if !center.profileEnabled(for: page) { return "The built-in ad blocker is off. You can change this in Settings." }
        if center.isPrivate(page.profile) { return center.enabled(for: page) ? "On for this site. Changes last for this private session." : "Off for this private session. Switching reloads the page." }
        return center.enabled(for: page) ? "The built-in ad blocker is turned on for this site." : "The built-in ad blocker is disabled for this site."
    }
}

/// Extension changes always require explicit consent, including after migration.
struct BlockingOfferCard: View {
    @ObservedObject var center: BlockingCenter
    let profile: String
    var answered: () -> Void = {}
    @Environment(\.aircTheme) private var theme
    @State private var problem: String?
    var body: some View {
        let blockers = center.blockers(profile: profile)
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "shield.lefthalf.filled").font(.system(size: 24, weight: .medium)).foregroundStyle(theme.accent.color)
            Text("Choose your ad blocker").aircFont(AircFont.title3)
            Text("Airc’s built-in protection is on for \(center.profileName(profile)). You also have \(blockers.map(\.name).joined(separator: ", ")). Using one blocker can help pages work smoothly.")
                .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Keep Both") {
                    center.settings.dismissCoexistence(profile: profile, extensionIDs: blockers.map(\.id))
                    answered()
                }.buttonStyle(.airc(.secondary))
                Spacer(minLength: 8)
                Button("Turn Off Other Blockers") {
                    if center.disableOtherBlockers(profile: profile, extensions: blockers.map(\.id)) { answered() }
                    else { problem = "An extension couldn’t be changed. You can manage it in Extensions." }
                }.buttonStyle(.airc(.primary))
            }
            if let problem { Text(problem).aircFont(AircFont.caption).foregroundStyle(AircColor.destructive.color) }
        }.foregroundStyle(theme.surfaceText.color)
    }
}

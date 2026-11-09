// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import SwiftUI

/// Settings → Site Search (Arc's "Site search" in its search engine settings, docs/user/command-bar.md): each profile's
/// sites, their shortcuts and search addresses ("URL with %s in place of query"), adding, editing and removing them,
/// whether Space starts a site search as well as Tab, and (P07d) which site, if any, is the profile's default search
/// engine. Profiles keep separate lists, as Arc's do.
struct SiteSearchSettingsPage: View {
    @ObservedObject var model: SettingsModel
    /// Whose sites are shown; nil: the current Space's profile.
    @State private var chosenProfile: String?
    @State private var name = ""
    @State private var keyword = ""
    @State private var template = ""
    @State private var problem: SiteSearchProblem?
    @State private var editing: SiteSearch?
    @Environment(\.aircTheme) private var theme

    private var profiles: [Profile] { model.store.orderedProfiles }
    private var profileID: String {
        if let id = chosenProfile, profiles.contains(where: { $0.id == id }) { return id }
        return model.store.profile(ofSpace: model.store.selectedSpace.id).id
    }
    private var searches: [SiteSearch] { model.settings.values.siteSearch.searches(for: profileID) }
    private var builtIn: SearchEngine { model.store.profile(profileID)?.searchEngine ?? .google }
    private var defaultID: String? { model.settings.values.siteSearch.defaultSite(for: profileID)?.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Search a site straight from the Command Bar: press ⌘T, type the site's shortcut or the start of its name, press Tab, then type what you're looking for and press Return.")
                .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            if profiles.count > 1 {
                SettingsSection(title: "Profile", help: "Each profile has its own sites, like its own history and search engine.") {
                    SettingsRow(title: "Sites of") {
                        AircPopUp(options: profiles.map { ($0.emoji.isEmpty ? $0.name : $0.emoji + " " + $0.name, $0.id) },
                                  selection: profileID, width: 180) { id in
                            chosenProfile = id
                            problem = nil
                        }
                    }
                }
            }
            // P07d: Chrome's "Make default" for a site search. Its fallback is the profile's own engine (Profiles).
            SettingsSection(title: "Default search engine",
                            help: "What Airc searches when what you type isn't a web address. If you remove the site, \(builtIn.name) is used again.") {
                SettingsRow(title: "Search with",
                            subtitle: defaultID == nil ? "The profile's search engine, set in Profiles." : "Site searches still start with their shortcut and Tab.") {
                    AircPopUp(options: [(builtIn.name, String?.none)] + searches.map { ($0.name, Optional($0.id)) },
                              selection: defaultID, width: 180) { id in
                        model.settings.values.siteSearch.setDefault(id, for: profileID)
                    }
                    .testAnchor("sitesearch.default")
                }
            }
            SettingsSection(title: "Sites", help: "In a site search, Backspace on an empty search or Esc goes back to the Command Bar.") {
                ForEach(searches) { s in siteRow(s) }
                if searches.isEmpty {
                    SettingsRow(title: "No sites", subtitle: "Add one below, or restore the default sites.") { EmptyView() }
                }
            }
            SettingsSection(title: "Add a site") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        AircTextField("Name", text: $name, placeholder: "YouTube",
                                      message: problem?.field == .name ? problem?.message : nil, isError: problem?.field == .name)
                        AircTextField("Shortcut", text: $keyword, placeholder: "yt",
                                      message: problem?.field == .keyword ? problem?.message : nil, isError: problem?.field == .keyword)
                            .frame(width: 140)
                    }
                    AircTextField("URL with %s in place of query", text: $template,
                                  placeholder: "https://www.youtube.com/results?search_query=%s",
                                  message: problem?.field == .template ? problem?.message : "Search the site for a word, copy the address, and put %s where the word was.",
                                  isError: problem?.field == .template)
                    HStack {
                        Spacer()
                        Button("Add Site", action: add).buttonStyle(.airc(.primary))
                            .disabled(name.isEmpty && keyword.isEmpty && template.isEmpty)
                    }
                }
                .padding(14)
            }
            SettingsSection(title: "Keyboard shortcut",
                            help: "Space starts a site search only right after a whole shortcut, like “yt ” — never after a name, so a search such as “you know” stays a search.") {
                SettingsRow(title: "Start a site search with") {
                    AircPopUp(options: [("Tab", false), ("Space or Tab", true)],
                              selection: model.settings.values.siteSearch.spaceTriggers(for: profileID), width: 150) { on in
                        model.settings.values.siteSearch.setSpaceTriggers(on, for: profileID)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Restore Default Sites") { model.settings.values.siteSearch.restoreDefaults(for: profileID) }
                    .buttonStyle(.airc(.secondary))
                    .help("Puts back the built-in sites you removed; your own stay")
            }
            .padding(.top, 16)
        }
        .sheet(item: $editing) { s in SiteSearchEditSheet(model: model, profileID: profileID, site: s) { editing = nil } }
        .onAppear {
            // Lists of deleted profiles go (Delete Profile removes the profile itself).
            let ids = Set(profiles.map(\.id))
            if model.settings.values.siteSearch.profiles.keys.contains(where: { !ids.contains($0) }) {
                model.settings.values.siteSearch.prune(keeping: ids)
            }
        }
    }

    private func siteRow(_ s: SiteSearch) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(s.name).aircFont(AircFont.body).foregroundStyle(theme.surfaceText.color)
                    if s.id == defaultID {
                        Text("Default").aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextSecondary.color)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(theme.surfaceText.alpha(0.06).color))
                    }
                }
                Text(s.template).aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextTertiary.color)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Text(s.keyword).aircFont(AircFont.mono).foregroundStyle(theme.surfaceTextSecondary.color)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(theme.surfaceText.alpha(0.06).color))
                .accessibilityLabel("Shortcut \(s.keyword)")
            Button("Edit") { editing = s }.buttonStyle(.airc(.plain))
            Button { model.settings.values.siteSearch.remove(s.id, from: profileID) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.airc(.plain)).accessibilityLabel("Remove \(s.name)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
    }

    private func add() {
        switch model.settings.values.siteSearch.add(name: name, keyword: keyword, template: template, to: profileID) {
        case .success:
            problem = nil
            name = ""; keyword = ""; template = ""
        case .failure(let p):
            problem = p
        }
    }
}

/// Editing one site: the same three fields and checks as adding one.
private struct SiteSearchEditSheet: View {
    @ObservedObject var model: SettingsModel
    let profileID: String
    let site: SiteSearch
    let close: () -> Void
    @State private var name = ""
    @State private var keyword = ""
    @State private var template = ""
    @State private var problem: SiteSearchProblem?
    @Environment(\.aircTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit \(site.name)").aircFont(AircFont.title2).foregroundStyle(theme.surfaceText.color)
            AircTextField("Name", text: $name, message: problem?.field == .name ? problem?.message : nil, isError: problem?.field == .name)
            AircTextField("Shortcut", text: $keyword, message: problem?.field == .keyword ? problem?.message : nil, isError: problem?.field == .keyword)
            AircTextField("URL with %s in place of query", text: $template,
                          message: problem?.field == .template ? problem?.message : nil, isError: problem?.field == .template)
            HStack {
                Spacer()
                Button("Cancel", action: close).buttonStyle(.airc(.plain)).keyboardShortcut(.cancelAction)
                Button("Save") {
                    switch model.settings.values.siteSearch.update(site.id, name: name, keyword: keyword, template: template, in: profileID) {
                    case .success: close()
                    case .failure(let p): problem = p
                    }
                }
                .buttonStyle(.airc(.primary)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .aircTheme(theme)
        .onAppear { name = site.name; keyword = site.keyword; template = site.template }
    }
}

// MARK: - A site search as the default engine (P07d)

extension AppSettings {
    /// What `profile` searches when what's typed isn't an address: its default site search (Settings → Site Search),
    /// else its built-in engine. A removed site falls back by itself (SiteSearchSettings.remove).
    func defaultSearch(for profile: Profile) -> DefaultSearch {
        values.siteSearch.defaultSearch(for: profile.id, engine: profile.searchEngine)
    }
}

extension Profile {
    /// The profile's default search, read from the app's settings (the built-in engine before they're loaded).
    var defaultSearch: DefaultSearch {
        (NSApp.delegate as? AppDelegate)?.settings?.defaultSearch(for: self) ?? .engine(searchEngine)
    }
}

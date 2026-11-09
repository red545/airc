// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit
import AircDesign
import SwiftUI

/// DEV-1 Developer Mode, Arc's Dev Tabs (docs/user/devmode.md): on per site (AircKit's DeveloperSitePolicy, Arc's
/// `enabledHosts` / `disabledDefaultHosts`), by itself for localhost, its subdomains and the loopback addresses (Settings'
/// "Turn on automatically for localhost", on as in Arc), and by hand for any other site from Site Controls, ⌃D or the
/// Command Bar. A site keeps its mode in every tab, Space, window and profile, across relaunches.
///
/// A tab in it shows its full URL, Inspect, Hard Reload and a count of its top-frame console.error calls, and its
/// sidebar row or Favorite tile takes the Developer Mode outline while selected. **Private windows never use it.**
///
/// Instrumentation: the page part posts "ready" from each top-frame http(s) document and does nothing else until Airc
/// answers that document (origin and frame checked) with "enabled": only then does it wrap console.error, as a
/// native-forwarding Proxy that keeps the page's call site. A site that's off, any private page and every frame below
/// the top get no wrapper. With no site able to be on (automatic off, none turned on), the part isn't installed at all.
/// Counts are local and ephemeral; no message text leaves JavaScript.
final class DeveloperMode: ObservableObject {
    static let shared = DeveloperMode()
    static let changed = Notification.Name("AircDeveloperModeChanged")
    /// A top-frame document that has the page part (it said "ready"), and whether Airc turned its counter on.
    private final class Entry {
        weak var tab: EngineTab?
        var frame: String
        var origin: String
        var enabled = false
        var count = 0
        /// The page part's own random token: counts are taken only from the copy Airc turned on.
        var token: String
        init(_ tab: EngineTab, frame: String, origin: String, token: String) {
            self.tab = tab; self.frame = frame; self.origin = origin; self.token = token
        }
    }
    private var entries: [ObjectIdentifier: Entry] = [:]
    private weak var settings: AppSettings?
    #if AIRC_TESTING
    /// Checks only: what the page parts said and what Airc answered, newest last.
    static var trace: [String] = []
    private static func traced(_ line: String) { trace.append(line); if trace.count > 60 { trace.removeFirst(20) } }
    #else
    private static func traced(_ line: @autoclosure () -> String) {}
    #endif
    /// Whether the page part is set now (nil before the first install).
    private var installed: Bool?

    /// Settings' "Turn on automatically for localhost" (Arc: always on).
    var automatic: Bool { settings?.values.developerAutomatic ?? true }
    var policy: DeveloperSitePolicy { settings?.values.developerSites ?? DeveloperSitePolicy() }
    /// Whether any site can be on now: the page part exists only then.
    private var anySiteCanBeOn: Bool { automatic || !policy.enabledHosts.isEmpty }

    func start(settings: AppSettings) {
        self.settings = settings
        install()
    }

    // MARK: Which pages

    /// Whether Developer Mode is on for `url` (a main window's page; private windows ask `applies(to:)`).
    func applies(_ url: String) -> Bool { policy.isOn(url, automatic: automatic) }

    /// Whether `tab` is in Developer Mode: its site is on and it isn't a private window's page.
    func applies(to tab: EngineTab?) -> Bool {
        guard let tab, !Self.isPrivate(tab) else { return false }
        return applies(tab.url?.absoluteString ?? "")
    }

    /// A private window's page (its profile is a private session's).
    static func isPrivate(_ tab: EngineTab) -> Bool {
        PrivateBrowsing.shared.windows.contains { $0.profile === tab.profile }
    }

    /// The URL field's text for a tab in Developer Mode: the whole URL (Arc: "Dev Tabs expose your URL at all times"),
    /// without a user name or password.
    static func displayURL(_ url: String) -> String {
        guard var u = URLComponents(string: url) else { return url }
        u.user = nil
        u.password = nil
        return u.string ?? url
    }

    /// The outline a selected row or tile of a tab in Developer Mode takes (Arc's yellow/black): yellow on dark
    /// themes, near-black on light ones.
    static func outlineColor(_ palette: Palette) -> NSColor {
        palette.isDark ? NSColor(srgbRed: 1, green: 0.80, blue: 0.16, alpha: 0.95) : NSColor(srgbRed: 0.09, green: 0.09, blue: 0.10, alpha: 0.85)
    }
    static let outlineWidth: CGFloat = 1.5

    /// Draws that outline on a row's plate or a Favorite's tile (`on`: selected and in Developer Mode), or removes it.
    /// The sidebar's one-line hooks (SidebarRows, SpacePage) call this from their updateStyle.
    static func outline(_ layer: CALayer, on: Bool, palette: Palette?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.borderWidth = on ? outlineWidth : 0
        if on, let palette { layer.borderColor = outlineColor(palette).cgColor }
        CATransaction.commit()
    }

    func count(_ tab: EngineTab?) -> Int? {
        guard let tab, let e = entries[ObjectIdentifier(tab)], e.tab === tab, e.enabled, Self.sameSite(e.origin, tab.url) else { return nil }
        return e.count
    }

    /// The entry's document is still what the tab shows, as far as its site goes (a navigation elsewhere hasn't said
    /// "ready" yet).
    private static func sameSite(_ origin: String, _ url: URL?) -> Bool {
        guard let url, let site = DeveloperSitePolicy.site(of: origin) else { return false }
        return site == DeveloperSitePolicy.site(of: url.absoluteString)
    }

    // MARK: Turning it on and off

    /// Settings' "Turn on automatically for localhost".
    func setAutomatic(_ on: Bool, app: AppDelegate) {
        guard let settings, settings.values.developerAutomatic != on else { return }
        settings.values.developerAutomatic = on
        Telemetry.shared.record(.featureUsed(.developerMode(on ? .on : .off)))
        policyChanged(app: app)
    }

    /// Site Controls, ⌃D and the Command Bar: Developer Mode on or off for the site of `url`. Returns the site.
    @discardableResult
    func set(_ url: String, on: Bool, app: AppDelegate) -> String? {
        guard let settings else { return nil }
        var p = settings.values.developerSites
        guard let site = p.set(url, on: on, automatic: automatic) else { return nil }
        if p != settings.values.developerSites {
            settings.values.developerSites = p
            Telemetry.shared.record(.featureUsed(.developerMode(on ? .on : .off)))
            policyChanged(app: app)
        }
        return site
    }

    /// Settings' Remove: the site goes back to its default.
    func forget(site: String, app: AppDelegate) {
        guard let settings else { return }
        var p = settings.values.developerSites
        p.forget(site: site)
        guard p != settings.values.developerSites else { return }
        settings.values.developerSites = p
        policyChanged(app: app)
    }

    /// The page part follows the policy; every open document whose state changed is turned on or off where it is, and
    /// a document without the part gets it (no reload, so form state stays).
    private func policyChanged(app: AppDelegate) {
        install()
        var seen = Set<ObjectIdentifier>()
        let tabs = (app.controllers.flatMap { Array($0.pages.values) } + entries.values.compactMap(\.tab))
            .filter { seen.insert(ObjectIdentifier($0)).inserted }
        for tab in tabs where !tab.isClosed {
            let on = applies(to: tab)
            if let e = entries[ObjectIdentifier(tab)], e.tab === tab, Self.sameSite(e.origin, tab.url) {
                guard e.enabled != on else { continue }
                if PageScripts.shared?.callDocument(tab, frame: e.frame, origin: e.origin, part: "devmode", kind: "enabled",
                                                    json: on ? "true" : "false") == true {
                    e.enabled = on
                    e.count = 0
                }
            } else if on {
                // Opened while no site could be on: its document never had the part.
                Self.traced("installNow")
                PageScripts.shared?.installNow("devmode", in: tab)
            }
        }
        objectWillChange.send()
        app.controllers.forEach { $0.reloadAll(animated: false) }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    private func install() {
        guard installed != anySiteCanBeOn else { return }
        installed = anySiteCanBeOn
        guard anySiteCanBeOn else {
            PageScripts.shared?.remove("devmode") { tab, message in
                // A document that finished installing while the last site was being turned off: off at once.
                if message.isMainFrame, message.kind == "ready" {
                    _ = PageScripts.shared?.callDocument(tab, frame: message.frame, origin: message.origin, part: "devmode", kind: "enabled", json: "false")
                }
            }
            for e in entries.values where e.enabled {
                if let tab = e.tab { _ = PageScripts.shared?.callDocument(tab, frame: e.frame, origin: e.origin, part: "devmode", kind: "enabled", json: "false") }
            }
            entries.removeAll()
            PageScripts.shared?.pushNow()
            return
        }
        PageScripts.shared?.set("devmode", source: Self.source) { [weak self] tab, m in
            guard let self, m.isMainFrame else { return }
            let id = ObjectIdentifier(tab)
            if m.kind == "ready" {
                self.entries = self.entries.filter { $0.value.tab != nil && !($0.value.tab!.isClosed) }
                let e = Entry(tab, frame: m.frame, origin: m.origin, token: m.json)
                self.entries[id] = e
                // The native decision: this document's site, never a private page.
                let on = !Self.isPrivate(tab) && self.policy.isOn(m.origin, automatic: self.automatic)
                let sent = on && PageScripts.shared?.callDocument(tab, frame: m.frame, origin: m.origin, part: "devmode", kind: "enabled", json: "true") == true
                Self.traced("ready \(m.json.prefix(6)) on \(on) sent \(sent)")
                if sent {
                    e.enabled = true
                    NotificationCenter.default.post(name: Self.changed, object: nil)
                }
            } else if m.kind == "count" {
                // "<token>:<n>": only the copy this document's entry turned on.
                let parts = m.json.split(separator: ":", maxSplits: 1).map(String.init)
                Self.traced("count \(m.json.prefix(12))")
                guard parts.count == 2, let n = Int(parts[1]), (0...9999).contains(n), let e = self.entries[id], e.enabled,
                      e.token == parts[0], e.origin == m.origin, e.count != n else { return }
                e.count = n
                self.countsChanged()
            }
        }
        PageScripts.shared?.pushNow()
    }

    /// A page logging an error every frame sends a count each time: the strips (every Space page's, in every window)
    /// redraw at most ten times a second.
    private var countsQueued = false
    private func countsChanged() {
        guard !countsQueued else { return }
        countsQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.countsQueued = false
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    /// The page part: no wrapper until Airc turns this document on (`enabled`), and none in frames below the top.
    private static let source = """
    function(post) {
      if (window.top !== window || !/^https?:$/.test(location.protocol)) return;
      var original = console.error, wrapped = null, active = false, n = 0, queued = false;
      var token = Math.random().toString(36).slice(2, 12);
      var apply = Reflect.apply, schedule = queueMicrotask.bind(window);
      // Proxy [[Call]] reads this getter, then calls its result. The getter has returned before
      // the native console runs: no JavaScript forwarding frame can replace the page's call site,
      // even when Chromium retains only one stack frame before DevTools has opened.
      var handler = { __proto__: null, get apply() {
        if (active && n < 9999) {
          n = Math.min(9999, n + 1);
          if (!queued) { queued = true; schedule(function() { queued = false; if (active) post('count', token + ':' + n); }); }
        }
        return apply;
      } };
      function enable(on) {
        if (on === active) return;
        active = on; n = 0;
        if (on) { original = console.error; wrapped = new Proxy(original, handler); console.error = wrapped; }
        else if (console.error === wrapped) console.error = original;
      }
      addEventListener('pagehide', function() { enable(false); });
      addEventListener('pageshow', function(e) { if (e.persisted) post('ready', token); });
      post('ready', token);
      return function(kind, json) { if (kind === 'enabled') enable(json === 'true'); };
    }
    """
}

extension WindowController {
    /// The page ⌃D and the Command Bar act on: the focused pane's, or the tab on screen.
    private var developerPage: EngineTab? { shownTabID.flatMap { engineTab(for: $0) } }

    /// ⌃D (Arc: "Toggles developer mode on or off for the current site") and the Command Bar.
    func toggleDeveloperModeForSite() {
        guard let app, let page = developerPage, let url = page.url?.absoluteString, DeveloperSitePolicy.site(of: url) != nil else {
            NSSound.beep()
            return showToast("Developer Mode is for web pages")
        }
        let on = !DeveloperMode.shared.applies(url)
        guard let site = DeveloperMode.shared.set(url, on: on, app: app) else { return NSSound.beep() }
        showToast(on ? "Developer Mode on for \(site)" : "Developer Mode off for \(site)")
    }

    /// Arc's "Turn On / Turn Off Developer Mode for This Site" in the Command Bar, on a web page.
    func developerCommandActions() -> [CommandAction] {
        guard let url = developerPage?.url?.absoluteString, DeveloperSitePolicy.site(of: url) != nil else { return [] }
        let on = DeveloperMode.shared.applies(url)
        var a: [CommandAction] = [.init(title: on ? "Turn Off Developer Mode for This Site" : "Turn On Developer Mode for This Site",
                      symbol: "chevron.left.forwardslash.chevron.right", hint: ShortcutCenter.hint("view.developerSite", "⌃D"),
                      keywords: ["developer", "dev", "devtools", "inspect", "console", "localhost"]) { [weak self] in
            self?.toggleDeveloperModeForSite()
        }]
        // The strip's clear-and-reload, for a page in Developer Mode whose site the engine named.
        if on, let strip = pageView(for: currentSpaceID)?.developerStrip, !strip.isHidden, let domain = strip.siteDataDomain {
            a.append(.init(title: "Clear Data for \(domain) and Its Subdomains and Reload", symbol: "trash", hint: "",
                           keywords: ["developer", "clear", "cookies", "cache", "storage", "site data", "reload"]) { [weak strip] in
                strip?.clearSiteDataAndReload()
            })
        }
        return a
    }
}

/// Site Controls' Developer Mode row (Arc's "Developer Mode" site setting): this site on or off.
struct DeveloperSiteRow: View {
    let page: EngineTab?
    let ui: ResolvedTheme
    @ObservedObject private var mode = DeveloperMode.shared

    static func shows(_ page: EngineTab?) -> Bool {
        guard let page, !DeveloperMode.isPrivate(page) else { return false }
        return DeveloperSitePolicy.site(of: page.url?.absoluteString ?? "") != nil
    }

    private var url: String { page?.url?.absoluteString ?? "" }
    private var site: String { DeveloperSitePolicy.site(of: url) ?? "" }

    var body: some View {
        let on = mode.applies(url)
        HStack(spacing: 8) {
            Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 11, weight: .semibold))
                .foregroundStyle((on ? ui.accent : ui.surfaceTextTertiary).color).frame(width: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text("Developer Mode").aircFont(AircFont.body).foregroundStyle(ui.surfaceText.color)
                Text(on ? (mode.policy.isAutomaticallyOn(url, automatic: mode.automatic) ? "On automatically for \(site)" : "On for \(site)")
                        : "Full URL and developer tools for \(site)")
                    .aircFont(AircFont.callout).foregroundStyle(ui.surfaceTextTertiary.color).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            AircSwitch(isOn: Binding(get: { mode.applies(url) }, set: { value in
                guard let app = NSApp.delegate as? AppDelegate else { return }
                mode.set(url, on: value, app: app)
            }))
            .help(on ? "Turn Developer Mode off for this site (⌃D)" : "Turn Developer Mode on for this site (⌃D)")
            .testAnchor("site.developerSwitch")
        }
        .frame(height: 36)
        .padding(.horizontal, AircSpacing.m)
    }
}

/// Settings → General → Developer Mode: Arc's automatic localhost, and the sites turned on or off by hand.
struct DeveloperSettingsSection: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var mode = DeveloperMode.shared
    @Environment(\.aircTheme) private var theme

    var body: some View {
        SettingsSection(title: "Developer Mode",
                        help: "A site in Developer Mode shows its full URL, Inspect, Hard Reload and its console errors, with an outline on its tab. "
                            + "Turn it on for any site in Site Controls or with ⌃D; it stays on for that site. Private windows never use it.") {
            AircToggleRow("Turn on automatically for localhost", subtitle: "localhost, its subdomains and 127.0.0.1, as in Arc.",
                          isOn: Binding(get: { mode.automatic }, set: { value in
                              if let app = model.app { mode.setAutomatic(value, app: app) }
                          }))
            ForEach(mode.policy.sites, id: \.self) { site in
                SettingsRow(title: site, subtitle: "On by hand") {
                    Button("Remove") { if let app = model.app { mode.forget(site: site, app: app) } }.buttonStyle(.airc(.secondary, size: .small))
                }
            }
            ForEach(mode.policy.disabledDefaultHosts.sorted(), id: \.self) { site in
                SettingsRow(title: site, subtitle: "Turned off") {
                    Button("Reset") { if let app = model.app { mode.forget(site: site, app: app) } }.buttonStyle(.airc(.secondary, size: .small))
                }
            }
        }
    }
}

/// Arc's dev toolbar under the URL field: Inspect, Network (Chromium) and the console badge open Developer Tools at
/// their panel, or select it in the open inspector, which keeps its state (P20a's EngineDeveloperCommands); Hard Reload,
/// whose menu clears the site's data and reloads. WebKit selects only its Console: its Inspect opens Web Inspector as
/// it was, and there's no Network button.
final class DeveloperStrip: NSView {
    private weak var tab: EngineTab?
    private var observer: NSObjectProtocol?
    private var palette: Palette?
    private var host: NSHostingView<DeveloperStripButtons>?
    /// The site the engine clears for this page (its registrable domain, or a local page's host), nil while unknown
    /// or unavailable: "Clear data for <domain> and its subdomains and reload".
    private(set) var siteDataDomain: String?
    private var domainAsked: (tab: ObjectIdentifier, host: String?, at: Date)?
    var countTitle: String { DeveloperMode.shared.count(tab).map { $0 >= 9999 ? "9999+" : String($0) } ?? "—" }
    var clearLabel: String? { siteDataDomain.map { "Clear data for \($0) and its subdomains and reload" } }
    /// Whether the engine can select Network (Chromium).
    var offersNetwork: Bool { tab.map { !($0 is WebKitTab) } ?? false }
    override init(frame: NSRect) {
        super.init(frame: frame)
        observer = NotificationCenter.default.addObserver(forName: DeveloperMode.changed, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func configure(tab: EngineTab?, palette: Palette) {
        self.tab = tab; self.palette = palette
        askSiteDataDomain()
        refresh()
    }
    /// Asks the engine once per page and host, and again (at most every 2 s) while it has no answer: WebKit names a
    /// site only once the site has stored something.
    private func askSiteDataDomain() {
        guard let tab else { siteDataDomain = nil; domainAsked = nil; return }
        let host = tab.url?.host
        let same = domainAsked?.tab == ObjectIdentifier(tab) && domainAsked?.host == host
        if same, siteDataDomain != nil || Date().timeIntervalSince(domainAsked?.at ?? .distantPast) < 2 { return }
        domainAsked = (ObjectIdentifier(tab), host, Date())
        if !same { siteDataDomain = nil }
        tab.siteDataDomain { [weak self, weak tab] result in
            guard let self, let tab, tab === self.tab, tab.url?.host == host else { return }
            // Only a name for this page's own host: Chromium answers from the last committed page, which is still the
            // previous site while a navigation starts. Otherwise it's asked again (above).
            let domain = (try? result.get())?.lowercased()
            let page = host?.lowercased() ?? ""
            self.siteDataDomain = domain.flatMap { page == $0 || page.hasSuffix("." + $0) ? $0 : nil }
            self.refresh()
        }
    }
    private func refresh() {
        guard let palette else { return }
        let buttons = DeveloperStripButtons(theme: palette.resolved, count: DeveloperMode.shared.count(tab),
            enabled: tab != nil, network: offersNetwork, clearLabel: clearLabel,
            inspect: { [weak self] in self?.openInspector() }, openNetwork: { [weak self] in self?.openNetwork() },
            reload: { [weak self] in self?.hardReload() }, clear: { [weak self] in self?.clearSiteDataAndReload() },
            console: { [weak self] in self?.openConsole() })
        if let host { host.rootView = buttons }
        else {
            let view = NSHostingView(rootView: buttons)
            view.sizingOptions = []
            addSubview(view); host = view
        }
        needsLayout = true
    }
    override func layout() { super.layout(); host?.frame = bounds }
    @objc func openInspector() { show(.elements) }
    @objc func openNetwork() { show(.network) }
    @objc func openConsole() { show(.console) }
    @objc func hardReload() { tab?.reloadIgnoringCache() }

    private func show(_ panel: EngineDevToolsPanel) {
        guard let tab else { return NSSound.beep() }
        tab.showDevTools(panel: panel) { [weak self, weak tab] result in
            guard case .failure(let error) = result else { return }
            // WebKit can't select Elements: Inspect opens Web Inspector (its own toggle, so not when it's open).
            if panel == .elements, case .unavailable = error, let tab, tab.isDevToolsOpen || tab.showDevTools(console: false) { return }
            self?.toast(error.localizedDescription)
        }
    }

    /// Clears the site's cookies, storage and caches in this tab's profile, then reloads (Arc's dev reload). Never a
    /// private window's: the strip doesn't show there, and the engine refuses.
    func clearSiteDataAndReload() {
        guard let tab, let domain = siteDataDomain else { return NSSound.beep() }
        tab.clearSiteDataAndReload { [weak self] result in
            switch result {
            case .success: self?.toast("Cleared data for \(domain) and reloaded")
            case .failure(let error): self?.toast(error.localizedDescription)
            }
        }
    }

    private func toast(_ text: String) {
        guard let c = (NSApp.delegate as? AppDelegate)?.controller(for: window) else { return NSSound.beep() }
        c.showToast(text)
    }
}

private struct DeveloperStripButtons: View {
    let theme: ResolvedTheme
    let count: Int?
    let enabled: Bool
    let network: Bool
    let clearLabel: String?
    let inspect: () -> Void
    let openNetwork: () -> Void
    let reload: () -> Void
    let clear: () -> Void
    let console: () -> Void
    private var countText: String { count.map { $0 >= 9999 ? "9999+" : String($0) } ?? "—" }
    private var consoleHelp: String {
        count.map { "\($0) top-frame console.error calls since load or enabling Developer Mode. Open Console." }
            ?? "Console count unavailable. Open Console."
    }
    private var reloadHelp: String {
        "Hard Reload, bypassing the cache (⇧⌘R)" + (clearLabel == nil ? "" : ". Control-click to clear the site's data and reload.")
    }
    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 260
            // The keycap only where it fits whole: icons only from 180 pt; with the labels and Network from 340 pt.
            let keycap = compact ? geometry.size.width >= 180 : (!network || geometry.size.width >= 340)
            HStack(spacing: 2) {
                Button(action: inspect) {
                    HStack(spacing: 4) {
                        Image(systemName: "hammer")
                        if !compact { Text("Inspect").truncationMode(.tail) }
                    }
                }
                .accessibilityLabel("Inspect: open Developer Tools / Web Inspector")
                .help("Inspect: open Developer Tools / Web Inspector")
                if network {
                    Button(action: openNetwork) { Image(systemName: "network") }
                        .accessibilityLabel("Network: open Developer Tools at its Network panel")
                        .help("Network: open Developer Tools at its Network panel")
                }
                Button(action: reload) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        if !compact { Text("Reload").truncationMode(.tail) }
                        if keycap { AircKeycap("⇧⌘R") }
                    }
                }
                .contextMenu {
                    Button("Hard Reload", action: reload)
                    if let clearLabel { Button(clearLabel, action: clear) }
                }
                .accessibilityLabel("Hard Reload, bypassing the cache")
                .help(reloadHelp)
                Spacer(minLength: 0)
                Button(action: console) {
                    Text(countText).monospacedDigit()
                        .foregroundStyle((count ?? 0) > 0 ? Color.orange : theme.textSecondary.color)
                        .padding(.horizontal, 6).frame(minWidth: 24, minHeight: 18)
                        .background(Capsule().fill((count ?? 0) > 0 ? Color.orange.opacity(0.14) : theme.pillFill.color))
                }
                .accessibilityLabel(consoleHelp).help(consoleHelp)
            }
            .buttonStyle(.airc(.plain, size: .small))
            .disabled(!enabled)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .aircTheme(theme)
    }
}

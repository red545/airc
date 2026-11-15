// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit
import SwiftUI

/// New Live Folder… and Edit Live Folder…: the source (your pull requests, review requests, or a repository's), its
/// filters (author, labels, drafts), and the profile's GitHub account. Arc's line under the source:
/// "Pull requests from you and your team will show up here automatically".
final class LiveFolderSheet: ObservableObject {
    enum Source: String, CaseIterable, Identifiable {
        case yours, reviews, repository
        var id: String { rawValue }
        var title: String {
            switch self {
            case .yours: "Your Pull Requests"
            case .reviews: "Review Requests"
            case .repository: "A Repository"
            }
        }
    }

    static var active: [ObjectIdentifier: LiveFolderSheet] = [:]

    @Published var source: Source = .yours
    @Published var repository = ""
    @Published var author = ""
    @Published var labels = ""
    @Published var includeDrafts = true
    @Published var tokenField = ""
    @Published private(set) var account: String?
    @Published private(set) var accountMessage: String?
    @Published private(set) var deviceCode: GitHubDeviceFlow.Code?
    @Published private(set) var busy = false

    let editing: String?
    let spaceID: String
    let profileID: String
    let sheet: NSWindow
    weak var parent: NSWindow?
    weak var controller: WindowController?
    private var signIn: Task<Void, Never>?

    init(controller: WindowController, spaceID: String, editing folderID: String? = nil) {
        self.controller = controller
        self.spaceID = spaceID
        editing = folderID
        parent = controller.window
        profileID = controller.store.profile(ofSpace: spaceID).id
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 470), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = folderID == nil ? "New Live Folder" : "Edit Live Folder"
        sheet.isReleasedWhenClosed = false
        account = GitHubAccounts.shared.login(forProfile: profileID)
        if let folderID, let q = LiveFolderCenter.shared.display(folderID)?.query {
            if q.repository != nil, !q.createdByMe, !q.reviewRequested { source = .repository }
            else if q.reviewRequested, !q.createdByMe { source = .reviews }
            repository = q.repository ?? ""
            author = q.author ?? ""
            labels = q.labels.joined(separator: ", ")
            includeDrafts = q.includeDrafts
        }
        sheet.contentView = NSHostingView(rootView: LiveFolderSheetView(model: self))
    }

    // MARK: The query

    var query: GitHubPullQuery {
        let repo = GitHubPullQuery.normalizedRepository(repository)
        let labelList = labels.split(separator: ",").map { String($0) }
        let a = author.isEmpty ? nil : author
        switch source {
        case .yours: return GitHubPullQuery(repository: repo, createdByMe: true, reviewRequested: true, author: a, labels: labelList, includeDrafts: includeDrafts)
        case .reviews: return GitHubPullQuery(repository: repo, reviewRequested: true, author: a, labels: labelList, includeDrafts: includeDrafts)
        case .repository: return GitHubPullQuery(repository: repo, author: a, labels: labelList, includeDrafts: includeDrafts)
        }
    }

    var repositoryProblem: String? {
        if source == .repository && repository.trimmingCharacters(in: .whitespaces).isEmpty { return "Type a repository, like owner/name." }
        if !repository.trimmingCharacters(in: .whitespaces).isEmpty && GitHubPullQuery.normalizedRepository(repository) == nil {
            return "That isn't a GitHub repository (owner/name)."
        }
        return nil
    }

    var needsSignIn: Bool { query.needsSignIn && account == nil }

    var sourceNote: String {
        switch source {
        case .yours: "Pull requests from you and your team will show up here automatically"
        case .reviews: "Pull requests waiting for your review show up here, and leave once they're merged or closed."
        case .repository: "Open pull requests of a public repository; no GitHub account needed. Sign in for a private one."
        }
    }

    // MARK: Sheet

    func present() {
        guard let parent, parent.attachedSheet == nil else { NSSound.beep(); return }
        Self.active[ObjectIdentifier(parent)] = self
        parent.beginSheet(sheet)
    }

    func close() {
        signIn?.cancel()
        guard let parent else { return }
        parent.endSheet(sheet)
        sheet.orderOut(nil)
        Self.active[ObjectIdentifier(parent)] = nil
    }

    /// Create Live Folder / Save.
    func commit() {
        guard repositoryProblem == nil, let controller else { return NSSound.beep() }
        let q = query
        close()
        if let editing {
            LiveFolderCenter.shared.setQuery(q, ofFolder: editing)
        } else if let folder = LiveFolderCenter.shared.create(query: q, title: nil, inSpace: spaceID, store: controller.store) {
            if controller.store.space(spaceID)?.pinnedCollapsed == true { try? controller.store.updateSpace(spaceID) { $0.pinnedCollapsed = false } }
            controller.showToast("Created \(folder.displayTitle) Live Folder")
        }
    }

    // MARK: Account

    private var client: GitHubClient { LiveFolderCenter.shared.client }

    /// Sign In with GitHub…: the device flow. The code is shown here and github.com/login/device opens in a tab.
    func startDeviceFlow() {
        let flow = GitHubAccounts.shared.deviceFlow(client: client)
        busy = true
        accountMessage = nil
        signIn?.cancel()
        signIn = Task { [weak self] in
            do {
                let code = try await flow.start()
                await MainActor.run {
                    guard let self else { return }
                    self.deviceCode = code
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code.userCode, forType: .string)
                    self.controller?.openHelpPage(code.verificationURL)
                }
                let token = try await flow.token(for: code)
                let r = await GitHubAccounts.shared.useToken(token, forProfile: self?.profileID ?? "", client: self?.client ?? flowClient(flow))
                await MainActor.run { self?.finishSignIn(r) }
            } catch let e as GitHubDeviceFlow.Failure {
                await MainActor.run { self?.failSignIn(e) }
            } catch {
                await MainActor.run { self?.busy = false; self?.deviceCode = nil }
            }
        }
    }

    /// Use Token: a personal access token (fine-grained, read-only "Pull requests" and "Metadata").
    func useToken() {
        let raw = tokenField
        busy = true
        accountMessage = nil
        Task { [weak self] in
            guard let self else { return }
            let r = await GitHubAccounts.shared.useToken(raw, forProfile: self.profileID, client: self.client)
            await MainActor.run { self.finishSignIn(r) }
        }
    }

    private func finishSignIn(_ r: Result<String, LiveFolderStatus>) {
        busy = false
        deviceCode = nil
        switch r {
        case .success(let login):
            account = login
            tokenField = ""
            accountMessage = nil
        case .failure(let status):
            accountMessage = status == .signedOut ? "GitHub didn't accept that token." : status.message
        }
    }

    private func failSignIn(_ e: GitHubDeviceFlow.Failure) {
        busy = false
        deviceCode = nil
        switch e {
        case .notConfigured: accountMessage = "This build has no GitHub app for signing in. Use a token instead."
        case .denied: accountMessage = "GitHub sign-in was cancelled."
        case .expired: accountMessage = "The code expired. Try again."
        case .failed(let why): accountMessage = "Couldn't sign in: \(why)"
        }
    }

    func signOut() {
        GitHubAccounts.shared.signOut(profileID: profileID)
        account = nil
        LiveFolderCenter.shared.accountChanged(profileID: profileID)
    }

    var canDeviceFlow: Bool { GitHubAccounts.shared.canUseDeviceFlow }
    var profileName: String { controller?.store.profile(profileID)?.name ?? "this profile" }
}

private func flowClient(_ flow: GitHubDeviceFlow) -> GitHubClient { GitHubClient(http: flow.http, endpoint: flow.endpoint) }

struct LiveFolderSheetView: View {
    @ObservedObject var model: LiveFolderSheet

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.pull").font(.system(size: 22, weight: .medium)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.editing == nil ? "New Live Folder" : "Edit Live Folder").font(.headline)
                    Text("GitHub pull requests, kept up to date").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Picker("Show", selection: $model.source) {
                ForEach(LiveFolderSheet.Source.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("liveFolder.source")
            Text(model.sourceNote).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Form {
                TextField(model.source == .repository ? "Repository" : "Repository (optional)", text: $model.repository,
                          prompt: Text("owner/name"))
                TextField("Author", text: $model.author, prompt: Text("anyone"))
                TextField("Labels", text: $model.labels, prompt: Text("any; comma-separated"))
                Toggle("Include drafts", isOn: $model.includeDrafts)
            }
            .formStyle(.columns)
            if let problem = model.repositoryProblem, !model.repository.isEmpty || model.source == .repository {
                Text(problem).font(.callout).foregroundStyle(.orange)
            }

            Divider()
            account
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
                Button(model.editing == nil ? "Create Live Folder" : "Save") { model.commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.repositoryProblem != nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder private var account: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("GitHub account for \(model.profileName)").font(.subheadline.weight(.semibold))
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }
            if let login = model.account {
                HStack {
                    Label("Signed in as \(login)", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                    Spacer()
                    Button("Sign Out") { model.signOut() }
                }
            } else {
                Text(model.needsSignIn ? "Not signed in to GitHub. This folder needs an account to list your pull requests."
                                       : "Not signed in to GitHub. Public repositories work without an account.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let code = model.deviceCode {
                    HStack(spacing: 8) {
                        Text(code.userCode).font(.system(.title3, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                        Text("Copied. Enter it on the GitHub page that just opened.").font(.callout).foregroundStyle(.secondary)
                    }
                } else if model.canDeviceFlow {
                    Button("Sign In with GitHub…") { model.startDeviceFlow() }.disabled(model.busy)
                }
                HStack {
                    SecureField("Personal access token", text: $model.tokenField)
                    Button("Use Token") { model.useToken() }.disabled(model.tokenField.isEmpty || model.busy)
                }
                Text("A fine-grained token with read-only Pull requests and Metadata is enough. It's kept in your Keychain.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let m = model.accountMessage { Text(m).font(.callout).foregroundStyle(.orange) }
        }
    }
}

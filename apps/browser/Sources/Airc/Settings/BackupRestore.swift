// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit
import SwiftUI

struct BackupRestoreSection: View {
    @ObservedObject var model: SettingsModel
    @State private var showing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Backups").aircFont(AircFont.title3)
            HStack {
                Button("Restore from Backup…") { showing = true }.buttonStyle(.airc(.secondary))
                Button("Open Backup Folder") {
                    do {
                        try FileManager.default.createDirectory(at: model.settings.backupDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(model.settings.backupDirectory)
                    } catch { model.controller?.showToast(error.localizedDescription) }
                }.buttonStyle(.airc(.plain))
            }
        }
        .padding(.top, 24)
        .sheet(isPresented: $showing) { BackupRestorePicker(model: model) }
    }
}

struct BackupRestorePicker: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.aircTheme) private var theme
    @State private var backups: [SpacesStore.BackupInfo] = []
    @State private var selected: SpacesStore.BackupInfo?
    @State private var data: Data?
    @State private var status = "Reading backups…"
    @State private var confirming = false
    @State private var restoring = false
    @State private var selectionRequest = UUID()

    static func date(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .standard) }
    static func confirmation(_ date: Date) -> String {
        "Replace your current Spaces, tabs and archive with this backup from \(Self.date(date))? A backup of the current state is saved first."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Restore from Backup").aircFont(AircFont.title2)
            Text("Choose a backup from your backup folder. Browser logins and extension files are not included.")
                .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(backups) { b in
                        Button {
                            confirming = false
                            data = nil
                            selected = nil
                            let request = UUID()
                            selectionRequest = request
                            status = "Reading backup…"
                            Task {
                                do {
                                    let (bytes, date) = try await Task.detached {
                                        let bytes = try Data(contentsOf: b.url)
                                        return (bytes, try SpacesStore.readBackup(bytes).exportedAt)
                                    }.value
                                    guard selectionRequest == request else { return }
                                    data = bytes
                                    selected = b
                                    status = Self.confirmation(date)
                                    confirming = true
                                } catch {
                                    guard selectionRequest == request else { return }
                                    status = error.localizedDescription
                                }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(b.date.map(Self.date) ?? b.url.lastPathComponent)
                                    Spacer()
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(b.size), countStyle: .file))
                                }
                                Text(b.problem ?? "\(b.spaces) Spaces, \(b.tabs) tabs, \(b.archived) archived")
                                    .foregroundStyle(theme.surfaceTextSecondary.color)
                            }
                            .aircFont(AircFont.body).padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.surfaceBorder.color.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).disabled(b.problem != nil)
                    }
                }
            }.frame(height: 240)
            Text(status).aircFont(AircFont.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.airc(.plain))
                if confirming {
                    Button("Restore Backup") {
                        guard let data, selected != nil, let app = model.app else { return }
                        restoring = true
                        status = "Restoring backup…"
                        Task {
                          defer { restoring = false }
                          do {
                            _ = try await app.restoreBackup(data)
                            dismiss()
                            model.controller?.showToast("Backup restored")
                        } catch { status = "Restore failed: \(error.localizedDescription)"; confirming = false }
                        }
                    }.buttonStyle(.airc(.secondary))
                }
            }
        }
        .disabled(restoring)
        .interactiveDismissDisabled(restoring)
        .padding(24).frame(width: 540)
        .background(theme.surface.color)
        .task {
            let folder = model.settings.backupDirectory
            do {
                backups = try await Task.detached { try SpacesStore.listBackups(in: folder) }.value
                status = backups.isEmpty ? "No backups in this folder yet." : "Choose a backup to review before restoring."
            } catch { status = "Could not read backups: \(error.localizedDescription)" }
        }
    }
}

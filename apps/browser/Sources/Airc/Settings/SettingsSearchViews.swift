// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import AircDesign
import AppKit
import SwiftUI

/// settingsux: the search field at the top of the Settings sidebar. ⌘F focuses it; ↑↓ choose a result, Return opens it,
/// Esc clears the search (a second Esc, on an empty field, gives the keyboard back to the pane).
struct SettingsSearchField: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.aircTheme) private var theme
    @State private var focused = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle((focused ? theme.accent : theme.surfaceTextTertiary).color)
            SettingsSearchTextField(model: model, focused: $focused, textColor: theme.surfaceText.nsColor,
                                    placeholderColor: theme.surfaceTextTertiary.nsColor)
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                        .foregroundStyle(theme.surfaceTextTertiary.color)
                }
                .buttonStyle(.plain)
                .help("Clear")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(AircFieldBackground(isFocused: focused))
        .aircAnimation(AircCurve.previewIn, value: focused)
        .testAnchor("settings.search")
    }
}

/// The field itself: an NSTextField, so ⌘F can focus it and ↑↓ Return Esc reach the results (doCommandBy).
private struct SettingsSearchTextField: NSViewRepresentable {
    @ObservedObject var model: SettingsModel
    @Binding var focused: Bool
    let textColor: NSColor
    let placeholderColor: NSColor

    final class Field: NSTextField {
        var onFocus: ((Bool) -> Void)?
        override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            if ok { onFocus?(true) }
            return ok
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SettingsSearchTextField
        var focusRequest: Int
        init(_ parent: SettingsSearchTextField) {
            self.parent = parent
            focusRequest = parent.model.focusSearchRequest
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.model.query = field.stringValue
        }
        func controlTextDidEndEditing(_ note: Notification) { parent.focused = false }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let model = parent.model
            switch selector {
            case #selector(NSResponder.moveDown(_:)): model.moveSelection(1); return true
            case #selector(NSResponder.moveUp(_:)): model.moveSelection(-1); return true
            case #selector(NSResponder.insertNewline(_:)):
                if !model.query.trimmingCharacters(in: .whitespaces).isEmpty { model.openSelection() }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                if model.query.isEmpty {
                    control.window?.makeFirstResponder(nil)
                } else {
                    model.query = ""
                    textView.string = ""
                }
                return true
            default: return false
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Search Settings")
        field.setAccessibilityRole(.textField)
        field.onFocus = { [weak coordinator = context.coordinator] on in
            DispatchQueue.main.async { coordinator?.parent.focused = on }
        }
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        field.textColor = textColor
        field.placeholderAttributedString = NSAttributedString(string: "Search", attributes: [
            .foregroundColor: placeholderColor, .font: NSFont.systemFont(ofSize: 13)])
        if field.stringValue != model.query, field.currentEditor() == nil || model.query.isEmpty {
            field.stringValue = model.query
        }
        if context.coordinator.focusRequest != model.focusSearchRequest {
            context.coordinator.focusRequest = model.focusSearchRequest
            DispatchQueue.main.async {
                guard let window = field.window else { return }
                window.makeFirstResponder(field)
                field.currentEditor()?.selectAll(nil)
            }
        }
    }
}

/// The results, in the sidebar in place of the panes: title, and pane › section under it.
struct SettingsSearchResults: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.aircTheme) private var theme

    var body: some View {
        if model.results.isEmpty {
            Text("No results for “\(model.query.trimmingCharacters(in: .whitespaces))”")
                .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8).padding(.top, 6)
                .testAnchor("settings.search.none")
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.results.enumerated()), id: \.offset) { i, e in
                            row(e, selected: model.selection == i)
                                .id(i)
                                .onTapGesture {
                                    model.selection = i
                                    model.open(e)
                                }
                                .testAnchor("settings.search.result.\(i)")
                        }
                    }
                }
                .onChange(of: model.selection) { _, i in
                    if let i { proxy.scrollTo(i) }
                }
            }
        }
    }

    private func row(_ e: SettingsSearch.Entry, selected: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: e.page.symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(e.page.tint.color))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.title).aircFont(AircFont.body).foregroundStyle(theme.surfaceText.color).lineLimit(2)
                Text(e.path).aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextSecondary.color).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(selected ? theme.accent.alpha(0.18).color : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AircDesign
import SwiftUI

/// Arc's icon picker, emoji tab (273×273): a grid with a "none" button.
struct EmojiPicker: View {
    var onPick: (String?) -> Void
    @State private var query = ""

    static let emoji: [(String, String)] = [
        ("👨🏻‍💻", "laptop work code"), ("💼", "work briefcase"), ("🏠", "home"), ("🎨", "art design studio"),
        ("📚", "books study"), ("🧪", "lab science"), ("🚀", "rocket launch"), ("💰", "money finance"),
        ("🤑", "money"), ("🕺", "dance fun"), ("🦄", "unicorn"), ("😺", "cat"), ("🌱", "plant growth"),
        ("☕️", "coffee"), ("🎧", "music"), ("🎮", "games"), ("✈️", "travel"), ("🏋️", "gym fitness"),
        ("🍳", "cooking food"), ("🛒", "shopping"), ("📈", "chart stocks"), ("🧠", "brain ideas"),
        ("🔬", "research"), ("🏝️", "holiday"), ("⚽️", "football sport"), ("🎬", "film video"),
        ("📝", "notes writing"), ("🔧", "tools"), ("🌙", "night"), ("☀️", "sun day"), ("🔥", "fire hot"),
        ("❤️", "heart love"), ("⭐️", "star"), ("🐶", "dog"), ("🌍", "world"), ("🏛️", "government"),
        ("🎓", "school"), ("🧾", "receipt bills"), ("📦", "box shipping"), ("🤖", "robot ai"),
        ("🦊", "fox"), ("🐙", "octopus github"), ("🌸", "flower"), ("🍕", "pizza"), ("🎯", "target goals"),
        ("💡", "idea"), ("🧘", "calm"), ("🗂️", "files"),
    ]

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Search", text: $query).textFieldStyle(.roundedBorder).controlSize(.small)
                Button { onPick(nil) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Remove icon")
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(27), spacing: 4), count: 8), spacing: 4) {
                    ForEach(filtered, id: \.0) { e in
                        Button { onPick(e.0) } label: { Text(e.0).font(.system(size: 19)).frame(width: 27, height: 27) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(10)
    }

    private var filtered: [(String, String)] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? Self.emoji : Self.emoji.filter { $0.1.contains(q) }
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

public enum ShortcutMigration {
    /// The layout supplies Shift's digit-row characters. Do not guess a US layout for another keyboard.
    public static func shiftedDigits(_ stored: [String: String], symbols: [String: String]) -> [String: String] {
        stored.mapValues { value in
            guard let key = KeyCombo(string: value), key.modifiers == [.shift, .command],
                  let digit = symbols[key.key], digit != key.key else { return value }
            return KeyCombo(digit, key.modifiers).string
        }
    }
}

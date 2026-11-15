// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

/// BST-2: syntax colouring for a Boost's code in the import review. A small scanner, never an evaluator: it splits the
/// text into runs that cover all of it, in order, so the review shows every character exactly once. `sensitive` marks
/// the calls a reviewer should look at first: ones that reach the network, run text as code or read stored data.
public enum BoostCodeTokens {
    public enum Kind: String, Sendable, Equatable {
        case plain, keyword, string, comment, number, sensitive, atRule, property
    }
    public enum Language: Sendable { case javaScript, css }

    public struct Token: Equatable, Sendable {
        public var kind: Kind
        public var text: String
    }

    static let keywords: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do",
        "else", "export", "extends", "false", "finally", "for", "function", "if", "in", "instanceof", "let", "new", "null",
        "of", "return", "static", "super", "switch", "this", "throw", "true", "try", "typeof", "undefined", "var", "void",
        "while", "with", "yield",
    ]
    static let sensitive: Set<String> = [
        "fetch", "XMLHttpRequest", "WebSocket", "EventSource", "sendBeacon", "eval", "Function", "cookie", "localStorage",
        "sessionStorage", "indexedDB", "postMessage", "open", "innerHTML", "outerHTML", "insertAdjacentHTML", "write",
        "setTimeout", "setInterval", "location", "clipboard",
    ]

    public static func tokens(_ source: String, _ language: Language) -> [Token] {
        let s = Array(source.unicodeScalars)
        var out: [Token] = []
        var i = 0
        func emit(_ kind: Kind, _ from: Int, _ to: Int) {
            guard to > from else { return }
            var text = String.UnicodeScalarView(); text.append(contentsOf: s[from..<to])
            if let last = out.last, last.kind == kind { out[out.count - 1].text += String(text) }
            else { out.append(Token(kind: kind, text: String(text))) }
        }
        func isIdentStart(_ c: Unicode.Scalar) -> Bool { c == "_" || c == "$" || CharacterSet.letters.contains(c) }
        func isIdent(_ c: Unicode.Scalar) -> Bool { isIdentStart(c) || CharacterSet.decimalDigits.contains(c) || (language == .css && c == "-") }
        var depth = 0  // CSS: inside a { } block
        while i < s.count {
            let c = s[i], next = i + 1 < s.count ? s[i + 1] : nil
            if c == "/" && next == "*" {
                var j = i + 2
                while j < s.count && !(s[j] == "*" && j + 1 < s.count && s[j + 1] == "/") { j += 1 }
                j = min(s.count, j + 2); emit(.comment, i, j); i = j
            } else if language == .javaScript && c == "/" && next == "/" {
                var j = i
                while j < s.count && s[j] != "\n" { j += 1 }
                emit(.comment, i, j); i = j
            } else if c == "\"" || c == "'" || (language == .javaScript && c == "`") {
                var j = i + 1
                while j < s.count && s[j] != c && !(c != "`" && s[j] == "\n") { j += s[j] == "\\" ? 2 : 1 }
                j = min(s.count, j + 1); emit(.string, i, j); i = j
            } else if CharacterSet.decimalDigits.contains(c) {
                var j = i
                while j < s.count && (CharacterSet.alphanumerics.contains(s[j]) || s[j] == "." || s[j] == "%") { j += 1 }
                emit(.number, i, j); i = j
            } else if language == .css && c == "@" {
                var j = i + 1
                while j < s.count && isIdent(s[j]) { j += 1 }
                emit(.atRule, i, j); i = j
            } else if isIdentStart(c) || (language == .css && c == "-") {
                var j = i
                while j < s.count && isIdent(s[j]) { j += 1 }
                var word = String.UnicodeScalarView(); word.append(contentsOf: s[i..<j])
                let w = String(word)
                let kind: Kind
                switch language {
                case .javaScript: kind = sensitive.contains(w) ? .sensitive : keywords.contains(w) ? .keyword : .plain
                case .css:
                    var k = j
                    while k < s.count && (s[k] == " " || s[k] == "\t") { k += 1 }
                    kind = depth > 0 && k < s.count && s[k] == ":" ? .property : .plain
                }
                emit(kind, i, j); i = j
            } else {
                if language == .css { if c == "{" { depth += 1 } else if c == "}" { depth = max(0, depth - 1) } }
                emit(.plain, i, i + 1); i += 1
            }
        }
        return out
    }
}

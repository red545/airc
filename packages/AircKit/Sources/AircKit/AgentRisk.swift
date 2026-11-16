// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

// The Airc Agent's safety gate (docs/design/agent.md, "Safety"): before an acting tool runs, Airc asks the page what the
// action would hit and classifies it. Paying, sending, posting, deleting and account changes need the person's yes.
// The classifier errs wide: a false positive costs one click, a false negative is the risk.

/// What an agent action would hit on the page, as a page script reports it.
public struct AgentElementFacts: Equatable, Sendable {
    /// button, link, textbox, checkbox… (ARIA role or the tag's implicit one).
    public var role: String
    public var tag: String
    /// Visible text, aria-label, value and title of the element (and of the button it is inside), joined.
    public var text: String
    /// The input's type (submit, reset, password, text…).
    public var inputType: String
    /// The element submits a form (a submit button, or Return in a form field).
    public var submitsForm: Bool
    /// The form's action address and method.
    public var formAction: String
    public var formMethod: String
    /// The form's fields: autocomplete, name, id, type, placeholder and aria-label of each, lowercased, joined.
    public var formFields: [String]
    /// The page's address and title.
    public var pageURL: String
    public var pageTitle: String

    public init(role: String = "", tag: String = "", text: String = "", inputType: String = "", submitsForm: Bool = false,
                formAction: String = "", formMethod: String = "", formFields: [String] = [], pageURL: String = "", pageTitle: String = "") {
        self.role = role
        self.tag = tag
        self.text = text
        self.inputType = inputType
        self.submitsForm = submitsForm
        self.formAction = formAction
        self.formMethod = formMethod
        self.formFields = formFields
        self.pageURL = pageURL
        self.pageTitle = pageTitle
    }

    /// From the page script's JSON object.
    public init(json o: [String: Any]) {
        func s(_ k: String) -> String { o[k] as? String ?? "" }
        self.init(role: s("role"), tag: s("tag"), text: s("text"), inputType: s("type"), submitsForm: o["submits"] as? Bool ?? false,
                  formAction: s("formAction"), formMethod: s("formMethod"), formFields: o["fields"] as? [String] ?? [],
                  pageURL: s("url"), pageTitle: s("title"))
    }
}

public enum AgentRiskCategory: String, Codable, Sendable, CaseIterable {
    case payment, send, post, delete, account

    /// The approval card's verb: "Pay on shop.example.com".
    public var verb: String {
        switch self {
        case .payment: return "Pay"
        case .send: return "Send"
        case .post: return "Post"
        case .delete: return "Delete"
        case .account: return "Change your account"
        }
    }
}

/// A risky action: what kind, and why Airc thinks so (shown on the card).
public struct AgentRisk: Equatable, Sendable {
    public var category: AgentRiskCategory
    public var reason: String

    public init(_ category: AgentRiskCategory, _ reason: String) {
        self.category = category
        self.reason = reason
    }

    // MARK: Words

    /// Whole-word (or whole-phrase) matches, lowercased; several languages for the commonest buttons.
    static let paymentWords = [
        "pay", "pay now", "buy", "buy now", "place order", "place your order", "purchase", "complete purchase", "checkout",
        "check out", "proceed to checkout", "confirm payment", "confirm purchase", "submit payment", "subscribe", "donate",
        "order now", "complete order", "submit order", "pay with", "add payment", "start subscription", "upgrade now",
        "jetzt kaufen", "kaufen", "bezahlen", "jetzt bezahlen", "zahlungspflichtig bestellen", "bestellen", "zur kasse",
        "payer", "acheter", "commander", "valider la commande", "pagar", "comprar", "realizar pedido", "finalizar compra",
        "paga", "acquista", "betalen", "kopen",
    ]
    static let sendWords = [
        "send", "send now", "send message", "send email", "reply", "reply all", "forward", "submit message", "send invite",
        "senden", "absenden", "antworten", "weiterleiten", "envoyer", "répondre", "enviar", "responder", "invia", "verzenden",
    ]
    static let postWords = [
        "post", "publish", "tweet", "share", "comment", "post comment", "reply to post", "repost", "retweet",
        "veröffentlichen", "posten", "teilen", "kommentieren", "publier", "partager", "publicar", "compartir", "pubblica",
    ]
    static let deleteWords = [
        "delete", "remove", "erase", "trash", "move to trash", "discard", "destroy", "delete account", "close account",
        "cancel subscription", "unsubscribe", "empty trash", "delete forever", "permanently delete", "wipe",
        "löschen", "entfernen", "kündigen", "supprimer", "eliminar", "borrar", "elimina", "verwijderen",
    ]
    static let accountWords = [
        "change password", "update password", "reset password", "sign out of all", "log out of all", "transfer", "withdraw",
        "send money", "wire", "add recipient", "change email", "disable two-factor", "turn off 2-step", "remove 2fa",
        "überweisen", "überweisung", "virement", "transferir",
    ]
    static let cardFieldHints = ["cc-number", "cc-csc", "cc-exp", "cc-name", "cardnumber", "card-number", "card_number",
                                 "creditcard", "credit-card", "cvc", "cvv", "csc", "securitycode", "security-code", "iban",
                                 "card number", "expiry", "expiration"]
    static let paymentPaths = ["/checkout", "/pay", "/payment", "/purchase", "/billing", "/order/confirm", "/cart/confirm",
                               "/buy", "/subscribe", "/kasse", "/bestellung"]
    static let paymentHosts = ["checkout.stripe.com", "pay.stripe.com", "www.paypal.com", "paypal.com", "checkout.shopify.com",
                               "pay.google.com", "secure.checkout", "checkout.", "pay.", "payments."]
    static let mailHosts = ["mail.google.com", "outlook.live.com", "outlook.office.com", "outlook.office365.com",
                            "mail.yahoo.com", "app.fastmail.com", "mail.proton.me"]

    static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "-") }).map(String.init)
    }

    /// The first phrase of `list` found as whole words in `text`.
    static func phrase(_ list: [String], in text: String) -> String? {
        let w = words(text)
        guard !w.isEmpty else { return nil }
        let joined = " " + w.joined(separator: " ") + " "
        return list.first { joined.contains(" " + words($0).joined(separator: " ") + " ") }
    }

    // MARK: Classify

    /// Nil: no approval needed. `action`: click, key-submit (Return in a field), navigate.
    public static func classify(_ f: AgentElementFacts, action: String) -> AgentRisk? {
        let label = AgentRedaction.label(f.text).map { "the “\($0)” \(f.role.isEmpty ? "control" : f.role)" } ?? "this control"
        let page = URL(string: f.pageURL)
        let host = page?.host?.lowercased() ?? ""
        let path = page?.path.lowercased() ?? ""
        let formURL = URL(string: f.formAction, relativeTo: page)?.absoluteURL
        let formPath = formURL?.path.lowercased() ?? ""
        let fields = f.formFields.joined(separator: " ").lowercased()
        let hasCardFields = cardFieldHints.contains { fields.contains($0) } || f.formFields.contains { $0.contains("cc-") }
        let isPaymentPlace = paymentPaths.contains { path.hasPrefix($0) || path.contains($0 + "/") || formPath.hasPrefix($0) }
            || paymentHosts.contains { $0.hasSuffix(".") ? host.hasPrefix($0) : host == $0 || host.hasSuffix("." + $0) }
        let isControl = f.submitsForm || ["button", "link", "menuitem", "submit"].contains(f.role) || f.tag == "button"
            || ["submit", "button", "image"].contains(f.inputType)

        if action == "navigate" {
            // A navigation alone pays nothing; only a payment provider's confirm-type address is gated.
            if paymentHosts.contains(where: { !$0.hasSuffix(".") && (host == $0 || host.hasSuffix("." + $0)) }), path.contains("confirm") || path.contains("pay") {
                return AgentRisk(.payment, "Opens a payment page on \(host)")
            }
            return nil
        }
        guard isControl || action == "key-submit" else { return nil }
        let text = f.text
        // Order: payment first (a "Buy and send" button is a payment), then account, delete, send, post.
        if let p = phrase(paymentWords, in: text) { return AgentRisk(.payment, "\(cap(label)) (“\(p)”)") }
        if f.submitsForm && hasCardFields { return AgentRisk(.payment, "Submits a form with card or bank fields") }
        if f.submitsForm && isPaymentPlace { return AgentRisk(.payment, "Submits a form on a checkout or payment page") }
        if let p = phrase(accountWords, in: text) { return AgentRisk(.account, "\(cap(label)) (“\(p)”)") }
        if f.inputType == "reset" { return AgentRisk(.delete, "Clears the form") }
        if let p = phrase(deleteWords, in: text) { return AgentRisk(.delete, "\(cap(label)) (“\(p)”)") }
        if let p = phrase(sendWords, in: text) { return AgentRisk(.send, "\(cap(label)) (“\(p)”)") }
        if let p = phrase(postWords, in: text) { return AgentRisk(.post, "\(cap(label)) (“\(p)”)") }
        // A compose form (recipient + subject/body) sent with Return or a nameless button.
        let looksLikeMail = (fields.contains("to") || fields.contains("recipient") || fields.contains("email"))
            && (fields.contains("subject") || fields.contains("message") || fields.contains("body"))
        if f.submitsForm && (looksLikeMail || mailHosts.contains(host)) { return AgentRisk(.send, "Sends a message") }
        if action == "key-submit", mailHosts.contains(host), f.role == "textbox" { return AgentRisk(.send, "Return in a message on \(host)") }
        return nil
    }

    private static func cap(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    // MARK: Prompt injection

    /// Phrases that address an AI agent rather than a reader. Lowercased, matched as whole words.
    static let injectionPhrases = [
        "ignore previous instructions", "ignore all previous instructions", "ignore the above", "ignore your instructions",
        "disregard previous instructions", "disregard your instructions", "forget your instructions", "new instructions",
        "you are now", "you are an ai", "as an ai agent", "attention ai", "dear ai", "hey ai", "note to ai",
        "to the ai agent", "ai agents reading this", "system prompt", "assistant:", "system:",
        "do not tell the user", "don't tell the user", "without telling the user", "without asking the user",
        "instead you must", "your new task", "your real task",
    ]

    /// The page asked the agent to do something: the sentence it's in (≤ 160 characters), or nil.
    public static func injection(in text: String) -> String? {
        let lower = text.lowercased()
        for p in injectionPhrases {
            let needle = p
            var searchFrom = lower.startIndex
            while let r = lower.range(of: needle, range: searchFrom..<lower.endIndex) {
                searchFrom = r.upperBound
                // Whole words only ("llm" isn't "allmost"); "assistant:" ends on punctuation.
                let before = r.lowerBound == lower.startIndex ? nil : lower[lower.index(before: r.lowerBound)]
                let after = r.upperBound == lower.endIndex ? nil : lower[r.upperBound]
                if let b = before, b.isLetter || b.isNumber { continue }
                if let a = after, (a.isLetter || a.isNumber), needle.last?.isLetter == true { continue }
                return sentence(around: r, in: text)
            }
        }
        return nil
    }

    static func sentence(around r: Range<String.Index>, in text: String) -> String {
        let stops: Set<Character> = [".", "!", "?", "\n"]
        var start = r.lowerBound
        while start > text.startIndex, !stops.contains(text[text.index(before: start)]) { start = text.index(before: start) }
        var end = r.upperBound
        while end < text.endIndex, !stops.contains(text[end]) { end = text.index(after: end) }
        if end < text.endIndex { end = text.index(after: end) }
        let s = text[start..<end].split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return s.count > 160 ? String(s.prefix(159)) + "…" : s
    }
}

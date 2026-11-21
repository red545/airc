// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit
import UserNotifications

/// "Needs you" (docs/user/agents.md): an agent's page that waits for the person (a sign-in page, a 401, an SSO step, a
/// captcha). Its row in the Agents folder says "Needs you · Sign in", the folder header gets a badge, and after a few
/// seconds (an agent may still fill a saved login) a macOS notification says so, if the person allows Airc's
/// notifications. Tool results that load or look at the page tell the agent it waits for the person, so it doesn't
/// type credentials or loop. The person signs in (in Watch with Take over, or in any tab of that profile: sessions are
/// the profile's), and the next look at the page clears the state.
///
/// The page is asked only facts (is there a visible password field, a captcha frame, the response status); never its
/// text or a field's value.
enum AgentNeedsYou {
    /// Hosts that are only sign-in pages (and SSO providers).
    static let loginHosts: [String] = ["accounts.google.com", "login.microsoftonline.com", "login.live.com", "login.microsoft.com",
                                       "appleid.apple.com", "idmsa.apple.com", "login.yahoo.com", "signin.aws.amazon.com",
                                       "id.atlassian.com", "auth.openai.com", "login.salesforce.com", "account.proton.me",
                                       "okta.com", "oktapreview.com", "onelogin.com", "auth0.com", "duosecurity.com", "pingone.com"]

    static let script = """
    (function(){var r={};function vis(e){var b=e.getBoundingClientRect(),s=getComputedStyle(e);return b.width>2&&b.height>2&&s.visibility!=='hidden'&&s.display!=='none'&&s.opacity!=='0';}
    var tf='input[type=email],input[type=text],input[type=tel],input:not([type])';
    r.password=[].slice.call(document.querySelectorAll('input[type=password]')).filter(vis).some(function(p){
    var f=p.form;if(!f)return false;return [].slice.call(f.querySelectorAll(tf)).filter(vis).length<=3;});
    r.loosePassword=[].slice.call(document.querySelectorAll('input[type=password]')).some(vis);
    r.captcha=!!document.querySelector('iframe[src*="recaptcha"],iframe[src*="hcaptcha.com"],iframe[src*="challenges.cloudflare.com"],.g-recaptcha,.h-captcha,.cf-turnstile,#challenge-form,#cf-challenge-running,#captcha-container,iframe[title*="captcha" i]');
    r.inputs=[].slice.call(document.querySelectorAll(tf)).some(vis);
    try{var n=performance.getEntriesByType('navigation')[0];r.status=n&&n.responseStatus||0;}catch(e){r.status=0;}
    r.host=location.hostname;r.path=location.pathname;return JSON.stringify(r);})()
    """

    /// "Sign in", "Captcha", or nil, from the page's facts.
    static func reason(_ f: [String: Any]) -> String? {
        if f["captcha"] as? Bool == true { return "Captcha" }
        if f["password"] as? Bool == true { return "Sign in" }
        if (f["status"] as? Int) == 401 { return "Sign in" }
        let host = (f["host"] as? String ?? "").lowercased(), path = (f["path"] as? String ?? "").lowercased()
        let loginHost = loginHosts.contains { host == $0 || host.hasSuffix("." + $0) }
        let loginPath = path.range(of: #"/(login|log-in|signin|sign-in|sso|saml|oauth2?/authorize|auth/realms|ap/signin)(/|$|\.)"#,
                                   options: .regularExpression) != nil
        // A sign-in form: a password field in a small form (a mailbox with a password box elsewhere isn't one), or a
        // login host or path with a field or a password on it.
        if (loginHost || loginPath), f["inputs"] as? Bool == true || f["loosePassword"] as? Bool == true { return "Sign in" }
        return nil
    }

    static func note(_ why: String, client: String) -> String {
        let task = why == "Captcha" ? "solve the captcha" : "sign in"
        return "This page waits for the person to \(task). Airc showed them “Needs you” in the Agents folder. Don't type passwords or codes. "
            + (why == "Captcha" ? "" : "If a saved login fits, click the field and call fill_saved_login; otherwise ")
            + "wait (the wait tool, e.g. 20 s), then wait_for_load or screenshot to see whether they're done. The profile's sign-ins are shared, so after they sign in elsewhere, reload."
    }

    // MARK: Notifications

    private static var notified: Set<String> = []
    private static var asked = false

    /// After 8 s, if the row still needs the person: one notification per row and reason. Scripted runs record it.
    static func notifyLater(rowID: String, client: String, site: String, why: String) {
        let key = rowID + "|" + why
        guard !notified.contains(key) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard AgentActivity.shared.model.row(rowID)?.needsYou == why, !notified.contains(key) else { return }
            notified.insert(key)
            AgentCenter.shared.onEvent?("needs-you-notified \(rowID) \(why)")
            if (NSApp.delegate as? AppDelegate)?.options.isAutomated == true { return }
            // agentux3: a click on it goes straight to the page (AgentAttention.NotificationDelegate).
            post(rowID: rowID, title: "\(client) needs you", body: why == "Captcha" ? "A captcha on \(site). Click to solve it in Airc."
                                                                                    : "Sign in to \(site) so \(client) can go on. Click to sign in.")
        }
    }

    static var delay: TimeInterval = 8

    private static func post(rowID: String, title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        let send = {
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body
            c.userInfo = ["agentRow": rowID]
            center.add(UNNotificationRequest(identifier: "agent-needs-you-" + rowID, content: c, trigger: nil))
        }
        center.getNotificationSettings { s in
            DispatchQueue.main.async {
                switch s.authorizationStatus {
                case .authorized, .provisional: send()
                case .notDetermined where !asked:
                    asked = true
                    center.requestAuthorization(options: [.alert, .sound]) { ok, _ in if ok { DispatchQueue.main.async(execute: send) } }
                default: break
                }
            }
        }
    }

    static func withdraw(rowID: String) {
        guard (NSApp.delegate as? AppDelegate)?.options.isAutomated != true else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["agent-needs-you-" + rowID])
    }
}

extension AgentCenter {
    /// Looks at the tab's page and updates its row; answers the reason (nil: the page doesn't need the person).
    func checkNeedsYou(_ w: AgentWindow, _ tab: EngineTab, _ done: @escaping (String?) -> Void) {
        guard !tab.isClosed, let tabID = w.tabs.first(where: { $0.tab === tab })?.id else { return done(nil) }
        w.driver.evaluate(tab, AgentNeedsYou.script) { value in
            let why = agentJSON(value).flatMap(AgentNeedsYou.reason)
            let rowID = AgentActivityModel.rowID(window: w.id, tab: tabID)
            AgentActivity.shared.setNeedsYou(rowID, why)
            done(why)
        }
    }
}

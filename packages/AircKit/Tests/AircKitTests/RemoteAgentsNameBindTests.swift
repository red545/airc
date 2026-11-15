// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// The listener's refresh plan (a partial bind is retried) and the MagicDNS name from `tailscale status --json`.
/// Made-up addresses and names only.
final class RemoteAgentsNameBindTests: XCTestCase {
    let v4 = TailnetAddress.Interface(name: "utun4", address: "100.101.102.103", index: 21)
    let v6 = TailnetAddress.Interface(name: "utun4", address: "fd7a:115c:a1e0::1234", index: 21)

    // MARK: Bind plan

    func testFirstRefreshOpensEverything() {
        let p = RemoteBindPlan(wanted: [v4, v6], listening: [])
        XCTAssertEqual(p.open, [v4, v6]); XCTAssertEqual(p.keep, []); XCTAssertEqual(p.close, []); XCTAssertFalse(p.isSteady)
    }

    func testPartialBindRetriesOnlyTheMissingAddress() {
        // Same addresses as before, but only the IPv4 socket bound last time: the next refresh retries IPv6 alone and
        // keeps the IPv4 socket (its connections stay up).
        let p = RemoteBindPlan(wanted: [v4, v6], listening: [v4])
        XCTAssertEqual(p.keep, [v4]); XCTAssertEqual(p.open, [v6]); XCTAssertEqual(p.close, [])
        XCTAssertFalse(p.isSteady)
        let other = RemoteBindPlan(wanted: [v4, v6], listening: [v6])
        XCTAssertEqual(other.keep, [v6]); XCTAssertEqual(other.open, [v4])
    }

    func testRetriesEveryRefreshUntilItBinds() {
        var listening: [TailnetAddress.Interface] = [v4]
        var tries = 0
        for refresh in 0..<4 {
            let p = RemoteBindPlan(wanted: [v4, v6], listening: listening)
            tries += p.open.count
            listening = p.keep + (refresh == 2 ? p.open : [])   // the third retry binds
        }
        XCTAssertEqual(tries, 3)
        XCTAssertTrue(RemoteBindPlan(wanted: [v4, v6], listening: listening).isSteady)
    }

    func testSteadyWhenAllBound() {
        XCTAssertTrue(RemoteBindPlan(wanted: [v4, v6], listening: [v6, v4]).isSteady)
        XCTAssertTrue(RemoteBindPlan(wanted: [], listening: []).isSteady)
    }

    func testGoneOrMovedAddressesClose() {
        let p = RemoteBindPlan(wanted: [v4], listening: [v4, v6])
        XCTAssertEqual(p.close, [v6]); XCTAssertEqual(p.keep, [v4]); XCTAssertEqual(p.open, [])
        // The same address on another interface (Tailscale restarted on a new utun) is a new socket.
        let moved = TailnetAddress.Interface(name: "utun7", address: v4.address, index: 30)
        let q = RemoteBindPlan(wanted: [moved], listening: [v4])
        XCTAssertEqual(q.close, [v4]); XCTAssertEqual(q.open, [moved])
        XCTAssertEqual(RemoteBindPlan(wanted: [], listening: [v4, v6]).close, [v4, v6])
    }

    // MARK: MagicDNS name

    func status(_ name: String = "my-mac.tailnet-a1b2.ts.net.", ips: [String] = ["100.101.102.103", "fd7a:115c:a1e0::1234"],
                backend: String = "Running", magic: Bool? = true, suffix: String = "tailnet-a1b2.ts.net") -> Data {
        var tailnet: [String: Any] = ["Name": "example.org"]
        if let magic { tailnet["MagicDNSEnabled"] = magic }
        let root: [String: Any] = [
            "Version": "1.90.0", "BackendState": backend, "MagicDNSSuffix": suffix, "CurrentTailnet": tailnet,
            "TailscaleIPs": ips,
            "Self": ["ID": "n1", "HostName": "My Mac", "DNSName": name, "TailscaleIPs": ips, "Online": true],
        ]
        return try! JSONSerialization.data(withJSONObject: root)
    }

    func testNameFromStatus() {
        XCTAssertEqual(TailscaleName.magicDNSName(statusJSON: status(), addresses: ["100.101.102.103"]), "my-mac.tailnet-a1b2.ts.net")
        XCTAssertEqual(TailscaleName.magicDNSName(statusJSON: status(), addresses: ["fd7a:115c:a1e0::1234"]), "my-mac.tailnet-a1b2.ts.net")
        XCTAssertEqual(TailscaleName.magicDNSName(statusJSON: status(), addresses: ["fd7a:115c:a1e0:0:0:0:0:1234"]), "my-mac.tailnet-a1b2.ts.net",
                       "addresses compare as addresses, not text")
        XCTAssertEqual(TailscaleName.magicDNSName(statusJSON: status("My-Mac.Tailnet-A1B2.ts.net."), addresses: ["100.101.102.103"]),
                       "my-mac.tailnet-a1b2.ts.net")
        XCTAssertEqual(TailscaleName.magicDNSName(statusJSON: status(magic: nil), addresses: ["100.101.102.103"]), "my-mac.tailnet-a1b2.ts.net",
                       "older clients don't say; the name still counts")
    }

    func testNoNameFallsBackToTheAddress() {
        let a = ["100.101.102.103"]
        XCTAssertNil(TailscaleName.magicDNSName(statusJSON: status(magic: false), addresses: a), "MagicDNS off")
        XCTAssertNil(TailscaleName.magicDNSName(statusJSON: status(backend: "Stopped"), addresses: a))
        XCTAssertNil(TailscaleName.magicDNSName(statusJSON: status(backend: "NeedsLogin"), addresses: a))
        XCTAssertNil(TailscaleName.magicDNSName(statusJSON: status(""), addresses: a))
        XCTAssertNil(TailscaleName.magicDNSName(statusJSON: status(), addresses: ["100.99.1.2"]), "another device's name")
        XCTAssertNil(TailscaleName.magicDNSName(statusJSON: status(), addresses: []))
        XCTAssertNil(TailscaleName.magicDNSName(statusJSON: status("my-mac.example.com."), addresses: a), "not a tailnet name")
        XCTAssertNil(TailscaleName.magicDNSName(statusJSON: Data("not json".utf8), addresses: a))
        XCTAssertNil(TailscaleName.magicDNSName(statusJSON: Data("{}".utf8), addresses: a))
        XCTAssertNil(TailscaleName.magicDNSName(statusJSON: Data("{\"Self\":{\"DNSName\":7}}".utf8), addresses: a))
    }

    func testCustomSuffixCounts() {
        XCTAssertEqual(TailscaleName.magicDNSName(statusJSON: status("my-mac.corp.example.", suffix: "corp.example"),
                                                  addresses: ["100.101.102.103"]), "my-mac.corp.example")
    }

    func testOnlyPlainHostNamesGoIntoTheCommand() {
        let a = ["100.101.102.103"]
        for bad in ["my mac.tailnet.ts.net.", "a;rm -rf ~.tailnet.ts.net.", "$(id).tailnet.ts.net.", "my-mac.tailnet.ts.net\n.",
                    "-mac.tailnet.ts.net.", "mac-.tailnet.ts.net.", "my..mac.ts.net.", "mäc.tailnet.ts.net.", "'x'.tailnet.ts.net.",
                    String(repeating: "a", count: 64) + ".tailnet.ts.net."] {
            XCTAssertNil(TailscaleName.magicDNSName(statusJSON: status(bad), addresses: a), bad)
        }
        XCTAssertTrue(TailscaleName.isHostName("my-mac-2.tailnet-a1b2.ts.net"))
        XCTAssertFalse(TailscaleName.isHostName("localhost"))
        XCTAssertFalse(TailscaleName.isHostName(""))
    }

    func testCLIPathsAndArguments() {
        XCTAssertEqual(TailscaleName.cliPaths.first, "/Applications/Tailscale.app/Contents/MacOS/Tailscale")
        XCTAssertTrue(TailscaleName.cliPaths.allSatisfy { $0.hasPrefix("/") })
        XCTAssertEqual(TailscaleName.arguments, ["status", "--json", "--peers=false"])
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

final class RemoteAgentsTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Address filter

    func testTailnetIPv4Range() {
        for a in ["100.64.0.0", "100.64.0.1", "100.101.102.103", "100.127.255.255"] {
            XCTAssertTrue(TailnetAddress.isTailnet(a), a)
        }
        for a in ["100.63.255.255", "100.128.0.0", "100.200.1.1", "10.0.0.1", "192.168.1.10", "127.0.0.1", "0.0.0.0",
                  "255.255.255.255", "169.254.1.1", "64.100.0.1"] {
            XCTAssertFalse(TailnetAddress.isTailnet(a), a)
        }
    }

    func testTailnetIPv6Range() {
        for a in ["fd7a:115c:a1e0::1", "fd7a:115c:a1e0::1234:5678", "FD7A:115C:A1E0:ab12:cd34::9", "fd7a:115c:a1e0::1%utun8"] {
            XCTAssertTrue(TailnetAddress.isTailnet(a), a)
        }
        for a in ["fd7a:115c:a1e1::1", "fd7a:115c::1", "fe80::1", "::1", "::", "fd00::1", "2001:db8::1", "::ffff:100.64.0.1"] {
            XCTAssertFalse(TailnetAddress.isTailnet(a), a)
        }
    }

    func testNamesAndGarbageNeverCount() {
        for a in ["", "localhost", "my-mac.tailnet.ts.net", "100.64.0", "100.64.0.1.5", "100.64.0.1:80", "*", "any"] {
            XCTAssertFalse(TailnetAddress.isTailnet(a), a)
        }
    }

    func testListenableKeepsOnlyTailnetAddressesNeverWildcards() {
        let all = [TailnetAddress.Interface(name: "lo0", address: "127.0.0.1", index: 1),
                   .init(name: "en0", address: "192.168.1.20", index: 4),
                   .init(name: "en0", address: "0.0.0.0", index: 4),
                   .init(name: "utun8", address: "fd7a:115c:a1e0::1234:5678", index: 26),
                   .init(name: "utun8", address: "fe80::1234:abcd%utun8", index: 26),
                   .init(name: "utun8", address: "100.101.102.103", index: 26),
                   .init(name: "utun8", address: "100.101.102.103", index: 26),
                   .init(name: "en1", address: "::", index: 5)]
        let keep = TailnetAddress.listenable(all)
        XCTAssertEqual(keep.map(\.address), ["100.101.102.103", "fd7a:115c:a1e0::1234:5678"], "IPv4 first, each once")
        XCTAssertTrue(keep.allSatisfy { $0.name == "utun8" })
        XCTAssertTrue(TailnetAddress.listenable([.init(name: "en0", address: "10.0.0.2", index: 4)]).isEmpty,
                      "no Tailscale: nothing to listen on")
    }

    func testPeerSockaddr() {
        var v4 = sockaddr_in()
        v4.sin_family = sa_family_t(AF_INET)
        inet_pton(AF_INET, "100.88.12.34", &v4.sin_addr)
        let t4 = withUnsafePointer(to: &v4) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { TailnetAddress.tailnetText($0) } }
        XCTAssertEqual(t4, "100.88.12.34")
        inet_pton(AF_INET, "192.168.1.5", &v4.sin_addr)
        let lan = withUnsafePointer(to: &v4) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { TailnetAddress.tailnetText($0) } }
        XCTAssertNil(lan)
        var v6 = sockaddr_in6()
        v6.sin6_family = sa_family_t(AF_INET6)
        inet_pton(AF_INET6, "fd7a:115c:a1e0::42", &v6.sin6_addr)
        let t6 = withUnsafePointer(to: &v6) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { TailnetAddress.tailnetText($0) } }
        XCTAssertEqual(t6, "fd7a:115c:a1e0::42")
    }

    // MARK: Tokens

    func testTokensAreLongRandomAndHashed() {
        let a = RemoteToken.generate(), b = RemoteToken.generate()
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasPrefix("airc_"))
        XCTAssertEqual(a.count, 5 + 43, "32 bytes, base64url without padding")
        XCTAssertFalse(a.contains("+") || a.contains("/") || a.contains("="))
        XCTAssertEqual(RemoteToken.hash(a).count, 32)
        XCTAssertEqual(RemoteToken.unhex(RemoteToken.hex(RemoteToken.hash(a))), RemoteToken.hash(a))
    }

    func testConstantTimeEqual() {
        XCTAssertTrue(RemoteToken.constantTimeEqual([1, 2, 3], [1, 2, 3]))
        XCTAssertFalse(RemoteToken.constantTimeEqual([1, 2, 3], [1, 2, 4]))
        XCTAssertFalse(RemoteToken.constantTimeEqual([1, 2, 3], [1, 2]))
        XCTAssertFalse(RemoteToken.constantTimeEqual([], [0]))
        XCTAssertTrue(RemoteToken.constantTimeEqual([], []))
        // 256 differing in length only by a multiple of 256 must still differ (the length XOR truncates to a byte).
        XCTAssertFalse(RemoteToken.constantTimeEqual([UInt8](repeating: 0, count: 256), []))
    }

    func testBearerParsing() {
        XCTAssertEqual(RemoteToken.bearer("Bearer abc"), "abc")
        XCTAssertEqual(RemoteToken.bearer("bearer  abc "), "abc")
        XCTAssertNil(RemoteToken.bearer("Basic abc"))
        XCTAssertNil(RemoteToken.bearer("Bearer "))
        XCTAssertNil(RemoteToken.bearer(nil))
    }

    func testRegistryAuthenticatesOnlyTheRightTokenAndStoresNoToken() throws {
        var r = RemoteDeviceRegistry()
        let (one, token1) = try XCTUnwrap(r.add(name: "build-box", now: t0, address: "100.88.12.34"))
        let (two, token2) = try XCTUnwrap(r.add(name: "laptop", now: t0))
        XCTAssertEqual(r.authenticate("Bearer " + token1)?.id, one.id)
        XCTAssertEqual(r.authenticate("Bearer " + token2)?.id, two.id)
        XCTAssertNil(r.authenticate("Bearer " + token1 + "x"))
        XCTAssertNil(r.authenticate("Bearer " + String(token1.dropLast())))
        XCTAssertNil(r.authenticate("Bearer " + RemoteToken.generate()))
        XCTAssertNil(r.authenticate(nil))
        XCTAssertNil(r.authenticate("Bearer " + one.tokenHash), "the stored hash isn't a token")
        let stored = String(decoding: r.encoded(), as: UTF8.self)
        XCTAssertFalse(stored.contains(token1) || stored.contains(token2), "tokens are never stored, only their hashes")
        XCTAssertEqual(RemoteDeviceRegistry.decode(r.encoded()), r)
    }

    func testRevokeEndsATokenAndOnlyThatOne() throws {
        var r = RemoteDeviceRegistry()
        let (one, token1) = try XCTUnwrap(r.add(name: "a", now: t0))
        let (_, token2) = try XCTUnwrap(r.add(name: "b", now: t0))
        XCTAssertTrue(r.revoke(one.id))
        XCTAssertFalse(r.revoke(one.id), "already gone")
        XCTAssertNil(r.authenticate("Bearer " + token1))
        XCTAssertNotNil(r.authenticate("Bearer " + token2))
        XCTAssertEqual(RemoteAgentGate.decide(method: "POST", path: "/mcp", headers: ["authorization": "Bearer " + token1],
                                              peer: "100.88.12.34", registry: r),
                       .reject(status: 401, reason: "unauthorized"))
    }

    func testRegistryIsCappedAndTouchIsThrottled() throws {
        var r = RemoteDeviceRegistry()
        for i in 0..<RemoteDeviceRegistry.maxDevices { XCTAssertNotNil(r.add(name: "d\(i)", now: t0)) }
        XCTAssertNil(r.add(name: "one too many", now: t0))
        let id = r.devices[0].id
        XCTAssertTrue(r.touch(id, now: t0, address: "100.64.0.9"))
        XCTAssertFalse(r.touch(id, now: t0.addingTimeInterval(30), address: "100.64.0.9"), "at most once a minute")
        XCTAssertTrue(r.touch(id, now: t0.addingTimeInterval(31), address: "100.64.0.10"), "a new address is remembered")
        XCTAssertTrue(r.touch(id, now: t0.addingTimeInterval(120), address: "100.64.0.10"))
        XCTAssertFalse(r.touch("nope", now: t0, address: nil))
    }

    // MARK: Pairing

    func testPairingCodeShapeAndOneUse() {
        var p = RemotePairing()
        XCTAssertEqual(p.attempt("ABCD-EFGH", peer: "100.64.0.2", now: t0), .noCode, "nothing to pair with until Settings shows a code")
        let shown = p.start(now: t0)
        XCTAssertEqual(shown.count, 9)
        XCTAssertEqual(shown[shown.index(shown.startIndex, offsetBy: 4)], "-")
        XCTAssertTrue(shown.replacingOccurrences(of: "-", with: "").allSatisfy { RemotePairing.alphabet.contains($0) })
        XCTAssertFalse(shown.contains("0") || shown.contains("O") || shown.contains("1") || shown.contains("I"))
        XCTAssertTrue(p.isActive(now: t0))
        XCTAssertEqual(p.attempt(shown.lowercased().replacingOccurrences(of: "-", with: " "), peer: "100.64.0.2", now: t0), .paired,
                       "case, spaces and dashes don't matter")
        XCTAssertFalse(p.isActive(now: t0))
        XCTAssertEqual(p.attempt(shown, peer: "100.64.0.2", now: t0), .noCode, "a code works once")
    }

    func testPairingCodeExpires() {
        var p = RemotePairing()
        let shown = p.start(now: t0)
        XCTAssertEqual(p.attempt(shown, peer: "100.64.0.2", now: t0.addingTimeInterval(RemotePairing.lifetime)), .noCode)
        XCTAssertNil(p.code)
    }

    func testPairingRateLimitsPerAddressAndOverall() {
        var p = RemotePairing()
        let shown = p.start(now: t0)
        for i in 0..<RemotePairing.perPeerPerMinute {
            XCTAssertEqual(p.attempt("WRONGWRN", peer: "100.64.0.2", now: t0.addingTimeInterval(Double(i))), .wrongCode)
        }
        guard case .rateLimited(let after) = p.attempt(shown, peer: "100.64.0.2", now: t0.addingTimeInterval(10)) else {
            return XCTFail("the sixth try in a minute is refused, even with the right code")
        }
        XCTAssertEqual(after, 50)
        XCTAssertEqual(p.attempt(shown, peer: "100.64.0.2", now: t0.addingTimeInterval(61)), .paired, "a minute later it works")

        var q = RemotePairing()
        let code = q.start(now: t0)
        for i in 0..<RemotePairing.allPerMinute {
            XCTAssertEqual(q.attempt("WRONGWRN", peer: "100.64.1.\(i)", now: t0), .wrongCode)
        }
        if case .rateLimited = q.attempt(code, peer: "100.64.2.1", now: t0) {} else { XCTFail("all addresses together are limited too") }
    }

    func testTwentyWrongGuessesBurnTheCode() {
        var p = RemotePairing()
        let shown = p.start(now: t0)
        var now = t0
        for i in 0..<RemotePairing.perCode {
            XCTAssertEqual(p.attempt("WRONGWRN", peer: "100.64.0.\(i % 2)", now: now), .wrongCode)
            now = now.addingTimeInterval(13)   // under every per-minute limit
        }
        XCTAssertNil(p.code)
        XCTAssertEqual(p.attempt(shown, peer: "100.64.0.9", now: now.addingTimeInterval(120)), .noCode)
    }

    func testDeviceNames() {
        XCTAssertEqual(RemotePairing.deviceName("build-box"), "build-box")
        XCTAssertEqual(RemotePairing.deviceName("  evil\u{0}\r\nname<script>  "), "evilnamescript")
        XCTAssertEqual(RemotePairing.deviceName(nil), "Another device")
        XCTAssertEqual(RemotePairing.deviceName(String(repeating: "x", count: 100)).count, 48)
    }

    // MARK: The gate

    func testGate() throws {
        var r = RemoteDeviceRegistry()
        let (d, token) = try XCTUnwrap(r.add(name: "a", now: t0))
        let auth = ["authorization": "Bearer " + token]
        let peer = "100.88.12.34"
        func decide(_ m: String, _ p: String, _ h: [String: String], peer: String = peer) -> RemoteAgentGate.Decision {
            RemoteAgentGate.decide(method: m, path: p, headers: h, peer: peer, registry: r)
        }
        XCTAssertEqual(decide("POST", "/mcp", auth), .mcp(deviceID: d.id))
        XCTAssertEqual(decide("DELETE", "/mcp", auth), .endSession(deviceID: d.id))
        XCTAssertEqual(decide("GET", "/mcp", auth), .reject(status: 405, reason: "method"))
        XCTAssertEqual(decide("POST", "/mcp", [:]), .reject(status: 401, reason: "unauthorized"))
        XCTAssertEqual(decide("POST", "/mcp", ["authorization": "Bearer nope"]), .reject(status: 401, reason: "unauthorized"))
        XCTAssertEqual(decide("GET", "/anything", [:]), .reject(status: 401, reason: "unauthorized"), "unpaired: nothing but 401")
        XCTAssertEqual(decide("GET", "/anything", auth), .reject(status: 404, reason: "path"))
        XCTAssertEqual(decide("POST", "/pair", [:]), .pair)
        XCTAssertEqual(decide("GET", "/pair", [:]), .reject(status: 405, reason: "method"))
        XCTAssertEqual(decide("POST", "/mcp", auth.merging(["origin": "https://evil.example"]) { $1 }), .reject(status: 403, reason: "origin"))
        XCTAssertEqual(decide("POST", "/mcp", auth, peer: "192.168.1.9"), .reject(status: 403, reason: "not on the tailnet"))
        XCTAssertEqual(decide("POST", "/pair", [:], peer: "127.0.0.1"), .reject(status: 403, reason: "not on the tailnet"))
    }
}

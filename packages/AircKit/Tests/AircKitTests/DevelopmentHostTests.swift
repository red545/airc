// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

final class DevelopmentHostTests: XCTestCase {
    func testDevelopmentDestinations() {
        for host in ["localhost", "LOCALHOST.", "app.localhost", "site.test", "build.local", "127.0.0.1", "127.255.3.4", "[::1]", "[0:0:0:0:0:0:0:1]", "[::ffff:127.0.0.1]", "10.0.0.1:3000", "172.16.0.1:80", "172.31.255.255:443", "192.168.2.3:8080", "169.254.1.2:80", "100.64.0.1:3000", "100.127.255.255:3000", "[fd00::12]:3000", "[fe80::1]:8080", "buildbox:3000"] {
            XCTAssertTrue(DevelopmentHost.matches("http://\(host)/path"), host)
        }
    }
    func testLookalikesAndPublicSites() {
        for host in ["localhost.example.com", "notlocalhost", "test", "local", "eviltest", "app.local.evil", "127.0.0.1.evil", "127.0.0.999", "10.0.0.1", "172.15.255.255:80", "172.32.0.1:80", "192.169.1.1:80", "100.63.255.255:80", "100.128.0.1:80", "[fd00::1]", "[2001:db8::1]:80", "[::]", "example.com:3000", "8.8.8.8:80", "localhost@evil.example"] {
            XCTAssertFalse(DevelopmentHost.matches("http://\(host)/"), host)
        }
        for url in ["file://localhost/x", "ftp://localhost/x", "localhost:3000", "about:blank", "javascript:alert(1)"] { XCTAssertFalse(DevelopmentHost.matches(url), url) }
    }
    func testOrigin() {
        XCTAssertEqual(DevelopmentHost.origin("http://user:secret@localhost:3000/a?q=secret#x"), "http://localhost:3000")
        XCTAssertEqual(DevelopmentHost.origin("https://[::1]:8443/path"), "https://[::1]:8443")
        XCTAssertNil(DevelopmentHost.origin("https://example.com"))
    }
}

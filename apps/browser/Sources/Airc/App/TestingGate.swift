// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import SwiftUI

// Test code compiles only with the AIRC_TESTING condition. scripts/build-app.sh sets it for dev and test builds (the
// nightly, the snapshot suite, perf runs, update proofs); scripts/release/package.sh builds without it, and
// scripts/release/check-release.py rejects a public bundle that still carries test code (docs/release.md, "Test code
// in public builds").
//
// Without it the app has no scripted scenarios (Debug/, all of it), no `--snapshot`, `--script`, `--automated`,
// `--onboarding` or `--perf-*` options, no `AIRC_AUTOMATED` and no bundle default options (`AircLaunchArguments`),
// no synthetic import or Keychain key, and it forwards none of the engine's `--airc-…` harness switches to
// Chromium (LaunchOptions). What stays are these stand-ins, so the views that mark test anchors and the hot paths that
// time their sections compile unchanged; they do nothing and inline away.
#if !AIRC_TESTING
extension View {
    func testAnchor(_ name: String) -> some View { self }
    func testAnchorRoot() -> some View { self }
}

enum Perf {
    static var enabled: Bool {
        get { false }
        set {}
    }

    @inline(__always) static func time<T>(_ name: String, _ body: () throws -> T) rethrows -> T { try body() }
}
#endif

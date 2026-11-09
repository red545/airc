// swift-tools-version:6.0
// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import PackageDescription

// Airc.app. `scripts/build-app.sh` builds this package and wraps the binary into build/Airc.app.
// Test code (Sources/Airc/Debug, the scripted-run options) compiles only with `-D AIRC_TESTING`, which build-app.sh
// passes for dev and test builds and scripts/release/package.sh leaves out (Sources/Airc/App/TestingGate.swift). A
// plain `swift build` is a public build.
let package = Package(
    name: "AircBrowser",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../packages/AircKit"),
        .package(path: "../../packages/AircDesign"),
        .package(path: "../../packages/AircImport"),
    ],
    targets: [
        .target(name: "AircCrashLog", path: "Sources/AircCrashLog"),
        .executableTarget(
            name: "Airc",
            dependencies: [
                "AircCrashLog",
                .product(name: "AircKit", package: "AircKit"),
                .product(name: "AircDesign", package: "AircDesign"),
                .product(name: "AircImport", package: "AircImport"),
            ],
            path: "Sources/Airc",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // agentspike: the stdio MCP helper (a pipe to the running Airc's agent socket; Sources/AircMCP/main.swift).
        .executableTarget(name: "AircMCP", path: "Sources/AircMCP", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)

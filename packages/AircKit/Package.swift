// swift-tools-version:6.0
// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import PackageDescription

// AircKit: Airc's model and product logic. No UI, no engine.
let package = Package(
    name: "AircKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AircKit", targets: ["AircKit"]),
    ],
    targets: [
        .target(
            name: "AircKit",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "AircKitTests", dependencies: ["AircKit"]),
    ]
)

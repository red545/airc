// swift-tools-version: 6.0
// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import PackageDescription
let package = Package(name: "AircImport", platforms: [.macOS(.v14)], products: [
    .library(name: "AircImport", targets: ["AircImport"])
], dependencies: [.package(path: "../AircKit")], targets: [
    .systemLibrary(name: "CArcCrypto"),
    .target(name: "AircImport", dependencies: ["CArcCrypto"], linkerSettings: [.linkedLibrary("sqlite3"), .linkedFramework("Security")]),
    .testTarget(name: "AircImportTests", dependencies: ["AircImport", "AircKit"], resources: [.copy("Fixtures")])
])

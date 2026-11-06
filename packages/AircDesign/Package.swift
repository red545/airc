// swift-tools-version: 6.0
// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
    name: "AircDesign",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AircDesign", targets: ["AircDesign"]),
        .executable(name: "aircdesign-gallery", targets: ["AircDesignGallery"]),
    ],
    targets: [
        .target(name: "AircDesign"),
        .executableTarget(name: "AircDesignGallery", dependencies: ["AircDesign"]),
        .testTarget(name: "AircDesignTests", dependencies: ["AircDesign"]),
    ]
)

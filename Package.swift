// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "abelia-signals",
    // Synchronization (Atomic, Mutex)
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AbeliaSignals", targets: ["AbeliaSignals"]),
    ],
    targets: [
        .target(
            name: "AbeliaSignals",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
                .enableExperimentalFeature("Lifetimes"),
            ],
        ),

        .executableTarget(
            name: "Playground",
            dependencies: [
                "AbeliaSignals"
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
                .enableExperimentalFeature("Lifetimes"),
            ],
        ),

        // v1: Signal / Computed / Effect
        .testTarget(
            name: "AbeliaSignalsTests",
            dependencies: ["AbeliaSignals"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
                .define("V1"),
            ],
        ),

        // v2: same tests (Correctness.swift is a symlink), node API via V2Shim
        .testTarget(
            name: "AbeliaSignalsV2Tests",
            dependencies: ["AbeliaSignals"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
                .define("V2"),
            ],
        ),
    ],
)

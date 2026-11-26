// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "abelia-signals",
    // Synchronization (Atomic, Mutex)
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AbeliaSignals", targets: ["AbeliaSignals"]),
        .library(name: "SignalGraph", targets: ["SignalGraph"]),
    ],
    targets: [
        .target(name: "AbeliaSignalsTLS"),

        .target(
            name: "AbeliaSignals",
            dependencies: ["AbeliaSignalsTLS"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
                .enableExperimentalFeature("Lifetimes"),
            ],
        ),

        // AttributeGraph's Swift API (as Compute / OpenAttributeGraph expose it) on AbeliaSignals' public API
        .target(
            name: "SignalGraph",
            dependencies: ["AbeliaSignals"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
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

        .testTarget(
            name: "AbeliaSignalsTests",
            dependencies: ["AbeliaSignals"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
    ],
    cLanguageStandard: .c2x,
)

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
        .target(name: "AbeliaSignalsTLS"),

        .target(
            name: "AbeliaSignals",
            dependencies: ["AbeliaSignalsTLS"],
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

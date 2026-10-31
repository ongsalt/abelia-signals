// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "abelia-signals",
    products: [
        .library(
            name: "AbeliaSignals",
            targets: ["AbeliaSignals"]
        )
    ],
    targets: [
        .target(
            name: "CAbeliaSignals",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ],
        ),
        .target(
            name: "AbeliaSignals",
            dependencies: [
                "CAbeliaSignals"
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ],
        ),
        .testTarget(
            name: "AbeliaSignalsTests",
            dependencies: ["AbeliaSignals"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ],
        ),
    ]
)

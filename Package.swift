// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "abelia-signals",
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

        // .testTarget(
        //     name: "AbeliaSignalsTests",
        //     dependencies: ["AbeliaSignals"]
        // ),
    ],
)

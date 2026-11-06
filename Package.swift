// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "abelia-signals",
    dependencies: [

    ],
    targets: [
        .target(
            name: "AbeliaSignals",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
                .enableExperimentalFeature("Lifetimes"),
            ],
        ),

        .target(
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

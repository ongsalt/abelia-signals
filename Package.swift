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

        .executableTarget(
            name: "Benchmark",
            dependencies: [
                "AbeliaSignals"
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
                .enableExperimentalFeature("Lifetimes"),
            ],
        ),

        // line-by-line alien-signals port, benchmark baseline only
        .target(
            name: "AlienSignals",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),

        // same sources as Benchmark (symlinked), compiled against AlienSignals
        .executableTarget(
            name: "BenchmarkAlien",
            dependencies: [
                "AlienSignals"
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
                .define("ALIEN"),
            ],
            // Double.rounded() in the harness needs libm; Benchmark gets it via Synchronization
            linkerSettings: [.linkedLibrary("m")],
        ),

        // .testTarget(
        //     name: "AbeliaSignalsTests",
        //     dependencies: ["AbeliaSignals"]
        // ),
    ],
)

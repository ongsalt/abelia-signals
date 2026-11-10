// swift-tools-version: 6.4

import PackageDescription

// Benchmarks for AbeliaSignals, kept out of the library package.
// Run from this directory: swift run -c release Benchmark [check|<filter>]
let package = Package(
    name: "abelia-signals-benchmarks",
    dependencies: [
        .package(path: "..")
    ],
    targets: [
        .executableTarget(
            name: "Benchmark",
            dependencies: [
                .product(name: "AbeliaSignals", package: "abelia-signals")
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
                .enableExperimentalFeature("Lifetimes"),
            ],
        ),

        // alien-signals port, benchmark baseline only
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
    ],
)

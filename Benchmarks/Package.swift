// swift-tools-version: 6.4

import PackageDescription

// Benchmarks for AbeliaSignals, kept out of the library package.
// Run from this directory: swift run -c release Benchmark [check|<filter>]
let package = Package(
    name: "abelia-signals-benchmarks",
    dependencies: [
        .package(path: ".."),
        // AttributeGraph reimplementation. Until the fix is upstream:
        //   swift package edit Compute
        //   add `#include <cstdint>` to Packages/Compute/Sources/ComputeCxx/Data/Pointer.h
        // and build with (libswiftDemangle is in the toolchain's usr/lib; the manifest cache
        // otherwise keeps Compute's pre-edit header paths):
        //   swift build -c release --manifest-cache none --product BenchmarkCompute \
        //     -Xlinker -L -Xlinker <toolchain>/usr/lib -Xlinker -rpath -Xlinker <toolchain>/usr/lib
        .package(url: "https://github.com/jcmosc/Compute", branch: "main"),
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

        // same sources as Benchmark (symlinked), compiled against Reactivity2's node API
        .executableTarget(
            name: "BenchmarkV2",
            dependencies: [
                .product(name: "AbeliaSignals", package: "abelia-signals")
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
                .define("V2"),
            ],
        ),

        // a subset of the suite on Compute: no effects, no create benchmarks
        .executableTarget(
            name: "BenchmarkCompute",
            dependencies: [
                .product(name: "Compute", package: "Compute")
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
            linkerSettings: [.linkedLibrary("m")],
        ),
    ],
)

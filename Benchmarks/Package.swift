// swift-tools-version: 6.4
// Separate from the library so it doesn't ship an executable. Run ./run.sh.
import PackageDescription

let package = Package(
    name: "Benchmarks",
    dependencies: [
        // SwiftPM names a path dependency after its folder
        .package(path: "..")
    ],
    targets: [
        .executableTarget(
            name: "Benchmarks",
            dependencies: [.product(name: "AbeliaSignals", package: "abelia-signals")],
        )
    ]
)

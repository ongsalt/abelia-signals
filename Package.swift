// swift-tools-version: 6.4

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "abelia-signals",
    // Synchronization (Atomic, Mutex)
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AbeliaSignals", targets: ["AbeliaSignals"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "604.0.0"),
    ],
    targets: [
        .target(name: "AbeliaSignalsTLS"),

        .macro(
            name: "AbeliaSignalsMacros",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),

        .target(
            name: "AbeliaSignals",
            dependencies: [
                "AbeliaSignalsTLS",
                "AbeliaSignalsMacros",
            ],
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

// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "abelia-signals",
    products: [
        .library(
            name: "AbeliaSignals",
            targets: ["AbeliaSignals"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "604.0.0")
    ],
    targets: [
        .target(
            name: "CAbeliaSignals",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ],
        ),
        .macro(
            name: "AbeliaSignalsMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "AbeliaSignals",
            dependencies: [
                "CAbeliaSignals",
                "AbeliaSignalsMacros",
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ],
        ),
        .testTarget(
            name: "AbeliaSignalsMacrosTests",
            dependencies: [
                "AbeliaSignalsMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "AbeliaSignalsTests",
            dependencies: ["AbeliaSignals"],
            path: "Tests/SignalsTests",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ],
        ),
    ]
)

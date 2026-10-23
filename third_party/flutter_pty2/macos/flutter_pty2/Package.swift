// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "flutter_pty2",
    platforms: [
        .macOS("10.15")
    ],
    products: [
        .library(
            name: "flutter-pty2",
            type: .dynamic,
            targets: ["flutter_pty2"]
        )
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "flutter_pty2",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            publicHeadersPath: "include",
            cSettings: [
                .define("DART_SHARED_LIB"),
                .headerSearchPath("include/flutter_pty2")
            ]
        )
    ]
)

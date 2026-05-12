// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TapedeckCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TapedeckCore", targets: ["TapedeckCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
    ],
    targets: [
        .target(
            name: "TapedeckCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "TapedeckCoreTests",
            dependencies: ["TapedeckCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)

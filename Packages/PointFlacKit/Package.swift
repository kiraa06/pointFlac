// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PointFlacKit",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "PFCore", targets: ["PFCore"])
    ],
    targets: [
        .target(
            name: "PFCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PFCoreTests",
            dependencies: ["PFCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

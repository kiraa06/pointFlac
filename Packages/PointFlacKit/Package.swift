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
        .target(
            name: "PFTestSupport",
            resources: [.copy("Resources/Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PFCoreTests",
            dependencies: ["PFCore", "PFTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

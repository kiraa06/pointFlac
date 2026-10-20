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
            name: "CFLAC",
            exclude: [
                "COPYING.Xiph",
                // Code fragments #included by other libFLAC sources; not standalone translation units.
                "libFLAC/deduplication",
            ],
            cSettings: [
                .define("HAVE_CONFIG_H"),
                .headerSearchPath("."),
                .headerSearchPath("include"),
                .headerSearchPath("libFLAC/include"),
                .unsafeFlags(["-w"]),
            ]
        ),
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
            name: "CFLACTests",
            dependencies: ["CFLAC", "PFTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PFCoreTests",
            dependencies: ["PFCore", "PFTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

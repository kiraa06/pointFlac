// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PointFlacKit",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "PFCore", targets: ["PFCore"]),
        .library(name: "PFFlac", targets: ["PFFlac"]),
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
                // libFLAC's own default (non --enable-debug) build: no assert() aborts and no debug prints to
                // stderr, such as "Rewinding, seeking necessary" when the decoder resyncs after a bad frame.
                .define("NDEBUG"),
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
            name: "PFFlac",
            dependencies: ["PFCore", "CFLAC"],
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
            name: "PFFlacTests",
            dependencies: ["PFFlac", "PFTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PFCoreTests",
            dependencies: ["PFCore", "PFTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

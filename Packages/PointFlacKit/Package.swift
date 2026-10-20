// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PointFlacKit",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "PFCore", targets: ["PFCore"]),
        .library(name: "PFFlac", targets: ["PFFlac"]),
        .library(name: "PFDSP", targets: ["PFDSP"]),
        .library(name: "PFAudio", targets: ["PFAudio"]),
        .library(name: "PFLibrary", targets: ["PFLibrary"]),
        .library(name: "PFSearch", targets: ["PFSearch"]),
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
            name: "PFDSP",
            dependencies: ["PFCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "PFAudio",
            dependencies: ["PFCore", "PFFlac", "PFDSP"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "PFLibrary",
            dependencies: ["PFCore", "PFFlac"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "PFSearch",
            dependencies: ["PFCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                // Search runs on every keystroke inside one 120 Hz frame (spec §8), so it is optimised in Debug builds
                // too: an unoptimised index loop is several times slower, and a Debug app or a `swift test` run would
                // then misstate the budget. Release builds are optimised anyway.
                .unsafeFlags(["-O"], .when(configuration: .debug)),
            ]
        ),
        .target(
            name: "PFTestSupport",
            dependencies: ["PFAudio"],
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
            name: "PFDSPTests",
            dependencies: ["PFDSP", "PFTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PFAudioTests",
            dependencies: ["PFAudio", "PFTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PFLibraryTests",
            // PFSearch and PFAudio only for the end-to-end test of the path the app adapter takes.
            dependencies: ["PFLibrary", "PFSearch", "PFAudio", "PFTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PFSearchTests",
            dependencies: ["PFSearch", "PFTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PFCoreTests",
            dependencies: ["PFCore", "PFTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

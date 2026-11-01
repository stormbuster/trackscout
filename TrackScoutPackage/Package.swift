// swift-tools-version: 6.1
// The TrackScout feature package.
//
// Note: the tools-version is 6.1 (so Swift Testing is discovered natively by
// SwiftPM / Xcode 16+), but both targets are explicitly compiled in the Swift 5
// language mode. The PRD targets iOS 17 and the project is intentionally built
// in Swift 5 mode to keep the first full build reliable; the code is written to
// be concurrency-correct so it can be bumped to Swift 6 later.

import PackageDescription

let swiftFive: [SwiftSetting] = [
    .swiftLanguageVersion(.v5),
]

let package = Package(
    name: "TrackScoutFeature",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "TrackScoutFeature",
            targets: ["TrackScoutFeature"]
        ),
    ],
    targets: [
        .target(
            name: "TrackScoutFeature",
            resources: [
                // The bundled demo questions file (§8.2 "Use demo data"): a
                // fully synthetic sample, shipped inside the app.
                .process("Resources"),
            ],
            swiftSettings: swiftFive
        ),
        .testTarget(
            name: "TrackScoutFeatureTests",
            dependencies: ["TrackScoutFeature"],
            resources: [
                // Copies of the bundled demo questions/answers files: the tests
                // exercise the same data the app ships on "Use demo data".
                .process("Fixtures"),
            ],
            swiftSettings: swiftFive
        ),
    ]
)

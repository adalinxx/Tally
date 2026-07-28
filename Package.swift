// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tally",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17), .watchOS(.v10), .visionOS(.v1)],
    products: [
        .library(name: "Tally", targets: ["Tally"]),
    ],
    dependencies: [
        // The lower bound carries a prerelease so a graph that also contains a
        // package pinning a swift-crypto prerelease can resolve; SwiftPM never
        // matches a prerelease against a range whose bounds are all releases.
        // Ordinary builds still take the newest stable release.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0-a"..<"6.0.0"),
    ],
    targets: [
        .target(
            name: "Tally",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "TallyTests",
            dependencies: ["Tally"]
        ),
        .executableTarget(
            name: "TallyBenchmarks",
            dependencies: ["Tally"],
            path: "Benchmarks/TallyBenchmarks"
        ),
    ]
)

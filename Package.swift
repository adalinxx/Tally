// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tally",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17), .watchOS(.v10), .visionOS(.v1)],
    products: [
        .library(name: "Tally", targets: ["Tally"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
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

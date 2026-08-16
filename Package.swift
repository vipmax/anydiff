// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AnyDiff",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AnyDiff", targets: ["AnyDiff"]),
        .library(name: "AnyDiffCore", targets: ["AnyDiffCore"]),
        .library(name: "AnyDiffUI", targets: ["AnyDiffUI"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "AnyDiffCore",
            dependencies: [],
            path: "Sources/AnyDiffCore"
        ),
        .target(
            name: "AnyDiffUI",
            dependencies: ["AnyDiffCore"],
            path: "Sources/AnyDiffUI"
        ),
        .executableTarget(
            name: "AnyDiff",
            dependencies: ["AnyDiffCore", "AnyDiffUI"],
            path: "Sources/AnyDiff"
        ),
        .testTarget(
            name: "AnyDiffCoreTests",
            dependencies: ["AnyDiffCore"],
            path: "Tests/AnyDiffCoreTests"
        )
    ]
)

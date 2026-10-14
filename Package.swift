// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Herd",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "HerdHelperKit",
            path: "Sources/HerdHelperKit"
        ),
        .executableTarget(
            name: "Herd",
            dependencies: ["HerdHelperKit"],
            path: "Sources/Herd",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "HerdHelper",
            dependencies: ["HerdHelperKit"],
            path: "Sources/HerdHelper"
        ),
        .testTarget(
            name: "HerdTests",
            dependencies: ["Herd", "HerdHelperKit"],
            path: "Tests/HerdTests"
        ),
    ]
)

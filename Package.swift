// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Herd",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Herd",
            path: "Sources/Herd",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
    ]
)

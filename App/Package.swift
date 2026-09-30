// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TidyUsage",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TidyUsage",
            path: "Sources/TidyUsage"
        ),
    ],
    swiftLanguageVersions: [.v5]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlexKit",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "PlexKit", targets: ["PlexKit"]),
    ],
    targets: [
        .target(
            name: "PlexKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PlexKitTests",
            dependencies: ["PlexKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

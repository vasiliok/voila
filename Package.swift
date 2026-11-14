// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AutoFrench",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "AutoFrench", targets: ["AutoFrench"]),
        .executable(name: "autofrench", targets: ["AutoFrenchCLI"]),
    ],
    targets: [
        .target(
            name: "AutoFrench",
            resources: [.copy("Resources/fr_50k.txt")]
        ),
        .executableTarget(
            name: "AutoFrenchCLI",
            dependencies: ["AutoFrench"]
        ),
        .testTarget(
            name: "AutoFrenchTests",
            dependencies: ["AutoFrench"]
        ),
    ]
)

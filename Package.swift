// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AutoFrench",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "AutoFrench", targets: ["AutoFrench"]),
        .executable(name: "autofrench", targets: ["AutoFrenchCLI"]),
        .executable(name: "AutoFrenchMenu", targets: ["AutoFrenchMenu"]),
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
        .executableTarget(
            name: "AutoFrenchMenu",
            dependencies: ["AutoFrench"]
        ),
        .testTarget(
            name: "AutoFrenchTests",
            dependencies: ["AutoFrench"]
        ),
        .testTarget(
            name: "AutoFrenchMenuTests",
            dependencies: ["AutoFrenchMenu"]
        ),
    ]
)

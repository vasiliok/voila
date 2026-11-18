// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Voila",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "Voila", targets: ["Voila"]),
        .executable(name: "voila", targets: ["VoilaCLI"]),
        .executable(name: "VoilaMenu", targets: ["VoilaMenu"]),
    ],
    targets: [
        .target(
            name: "Voila",
            resources: [.copy("Resources/fr_50k.txt")]
        ),
        .executableTarget(
            name: "VoilaCLI",
            dependencies: ["Voila"]
        ),
        .executableTarget(
            name: "VoilaMenu",
            dependencies: ["Voila"]
        ),
        .testTarget(
            name: "VoilaTests",
            dependencies: ["Voila"]
        ),
        .testTarget(
            name: "VoilaMenuTests",
            dependencies: ["VoilaMenu"]
        ),
    ]
)

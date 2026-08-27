// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Weebill",
    platforms: [
        .macOS(.v12), .iOS(.v15), .tvOS(.v15), .watchOS(.v8)
    ],
    products: [
        .library(name: "Weebill", targets: ["Weebill"]),
        .executable(name: "weebill-cli", targets: ["weebill-cli"])
    ],
    targets: [
        .target(name: "Weebill"),
        .executableTarget(name: "weebill-cli", dependencies: ["Weebill"]),
        .executableTarget(name: "c2fuzz", dependencies: ["Weebill"]),
        .testTarget(
            name: "WeebillTests",
            dependencies: ["Weebill"],
            resources: [.copy("Resources")]
        )
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pinebot",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PinebotKit", targets: ["PinebotKit"]),
        .executable(name: "PinebotApp", targets: ["PinebotApp"])
    ],
    targets: [
        .target(
            name: "PinebotKit",
            resources: [
                .process("Resources"),
                .copy("Router/classifier_sidecar.py")
            ]
        ),
        .executableTarget(
            name: "PinebotApp",
            dependencies: ["PinebotKit"]
        ),
        .testTarget(
            name: "PinebotKitTests",
            dependencies: ["PinebotKit"]
        )
    ]
)

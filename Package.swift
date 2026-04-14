// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TranscribeMacApp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "TranscribeMacApp", targets: ["TranscribeMacApp"])
    ],
    targets: [
        .executableTarget(
            name: "TranscribeMacApp",
            resources: [
                .process("Resources")
            ]
        )
    ]
)

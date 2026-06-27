// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SingAR",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SingAR",
            path: "Sources/SingAR"
        )
    ]
)

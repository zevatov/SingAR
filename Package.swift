// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SingAR",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "SingAR",
            targets: ["SingAR"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "SingAR",
            path: "Sources/SingAR"
        )
    ]
)

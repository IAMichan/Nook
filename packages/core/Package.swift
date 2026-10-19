// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NookCore",
    products: [.library(name: "NookCore", targets: ["NookCore"])],
    targets: [
        .target(name: "NookCore"),
        .testTarget(name: "NookCoreTests", dependencies: ["NookCore"]),
    ]
)

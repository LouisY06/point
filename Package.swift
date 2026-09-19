// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Point",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PointCore", targets: ["PointCore"]),
        .executable(name: "point-demo", targets: ["PointDemo"])
    ],
    targets: [
        .target(name: "PointCore"),
        .executableTarget(name: "PointDemo", dependencies: ["PointCore"]),
        .testTarget(name: "PointCoreTests", dependencies: ["PointCore"])
    ]
)

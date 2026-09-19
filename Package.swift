// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Point",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PointCore", targets: ["PointCore"]),
        .library(name: "PointSim", targets: ["PointSim"]),
        .executable(name: "point-demo", targets: ["PointDemo"]),
        .executable(name: "point-sim", targets: ["PointSimCLI"])
    ],
    targets: [
        .target(name: "PointCore"),
        // Simulation harness: depends on PointCore's public API only, never the other way round.
        .target(name: "PointSim", dependencies: ["PointCore"]),
        .executableTarget(name: "PointDemo", dependencies: ["PointCore"]),
        .executableTarget(name: "PointSimCLI", dependencies: ["PointSim"]),
        .testTarget(name: "PointCoreTests", dependencies: ["PointCore"]),
        .testTarget(name: "PointSimTests", dependencies: ["PointSim"])
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HealthSyncKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HealthSyncKit", targets: ["HealthSyncKit"]),
    ],
    targets: [
        .target(name: "HealthSyncKit"),
        .testTarget(name: "HealthSyncKitTests", dependencies: ["HealthSyncKit"]),
    ]
)

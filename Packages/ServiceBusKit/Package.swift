// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ServiceBusKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ServiceBusKit", targets: ["ServiceBusKit"]),
    ],
    targets: [
        .target(name: "ServiceBusKit"),
        .testTarget(name: "ServiceBusKitTests", dependencies: ["ServiceBusKit"]),
    ]
)

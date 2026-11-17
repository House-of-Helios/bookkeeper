// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BookkeeperCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BookkeeperCore", targets: ["BookkeeperCore"])
    ],
    targets: [
        .target(name: "BookkeeperCore"),
        // Fixtures are copied whole: `v1/` is a frozen 1.x data folder and `bank/` the
        // synthetic bank exports, both read as raw bytes.
        .testTarget(name: "BookkeeperCoreTests", dependencies: ["BookkeeperCore"],
                    resources: [.copy("Fixtures")])
    ]
)

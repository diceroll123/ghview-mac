// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ghview-mac",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "GHView", targets: ["GHView"]),
        .library(name: "GHCore", targets: ["GHCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/raspu/Highlightr.git", from: "2.3.0"),
    ],
    targets: [
        .target(name: "GHCore"),
        .executableTarget(name: "GHView", dependencies: ["GHCore", "Highlightr"]),
        .testTarget(name: "GHViewTests", dependencies: ["GHView", "GHCore"]),
        .testTarget(name: "GHCoreTests", dependencies: ["GHCore"], resources: [.copy("Fixtures")]),
    ]
)

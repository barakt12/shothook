// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Shothook",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure, AppKit-free logic: config, hotkey parsing, MRU routing, geometry.
        .target(name: "ShothookCore"),
        // The menu-bar agent itself.
        .executableTarget(
            name: "Shothook",
            dependencies: ["ShothookCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "ShothookCoreTests", dependencies: ["ShothookCore"]),
    ]
)

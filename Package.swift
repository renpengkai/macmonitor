// swift-tools-version:5.9
import PackageDescription

// 体积优先: 采样每 2 秒一次、计算量极小, -Osize 与 -O 无可感知差别
let sizeFlags: [SwiftSetting] = [.unsafeFlags(["-Osize"], .when(configuration: .release))]

let package = Package(
    name: "MacMonitor",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "SMCKit", path: "Sources/SMCKit", swiftSettings: sizeFlags),
        .executableTarget(name: "MacMonitor", dependencies: ["SMCKit"], path: "Sources/MacMonitor",
                          swiftSettings: sizeFlags),
        .executableTarget(name: "mmfanctl", dependencies: ["SMCKit"], path: "Sources/mmfanctl",
                          swiftSettings: sizeFlags),
    ]
)

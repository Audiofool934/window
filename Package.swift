// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "window",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WindowCore", targets: ["WindowCore"]),
        .executable(name: "Window", targets: ["WindowApp"]),
        .executable(name: "window-lab", targets: ["WindowLab"])
    ],
    targets: [
        // The shader source is compiled at runtime, so no Metal toolchain is needed to build.
        .target(name: "WindowCore", resources: [.copy("Shaders/Room.metal")]),
        .executableTarget(name: "WindowApp", dependencies: ["WindowCore"]),
        .executableTarget(name: "WindowLab", dependencies: ["WindowCore"]),
        .testTarget(name: "WindowCoreTests", dependencies: ["WindowCore"])
    ]
)

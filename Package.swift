// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "anemon",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CANEMon",
            linkerSettings: [.linkedFramework("CoreFoundation"), .linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "anemon",
            dependencies: ["CANEMon"]
        ),
        .target(
            name: "CANERun",
            linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("IOSurface")]
        ),
        .executableTarget(
            name: "anebench",
            dependencies: ["CANERun"]
        ),
    ]
)

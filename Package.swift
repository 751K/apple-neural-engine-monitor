// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "anemon",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CANEMon",
            linkerSettings: [.linkedFramework("CoreFoundation")]
        ),
        .executableTarget(
            name: "anemon",
            dependencies: ["CANEMon"]
        ),
    ]
)

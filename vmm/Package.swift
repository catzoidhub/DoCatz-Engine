// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "docatz-vmm",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "docatz-vmm",
            path: "Sources/docatz-vmm",
            linkerSettings: [.linkedFramework("Virtualization")]
        ),
    ]
)

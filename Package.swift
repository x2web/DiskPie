// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DiskPie",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DiskPie",
            path: "Sources/DiskPie"
        )
    ]
)

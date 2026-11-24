// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Sisifo",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "Sisifo", path: "Sources/Sisifo")
    ]
)

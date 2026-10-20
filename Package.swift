// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MossImage",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "MossImage", path: "Sources/MossImage")]
)

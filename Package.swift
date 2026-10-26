// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "CopyHistory",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "CopyHistory", targets: ["CopyHistory"]),
    .library(name: "CopyHistoryCore", targets: ["CopyHistoryCore"])
  ],
  targets: [
    .target(name: "CopyHistoryCore"),
    .executableTarget(name: "CopyHistory", dependencies: ["CopyHistoryCore"]),
    .testTarget(name: "CopyHistoryCoreTests", dependencies: ["CopyHistoryCore"])
  ]
)

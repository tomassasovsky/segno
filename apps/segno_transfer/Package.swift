// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "SegnoTransfer",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "SegnoTransfer", targets: ["SegnoTransfer"])],
  targets: [
    .target(name: "TransferCore", resources: [.copy("Resources/appliance.py")]),
    .executableTarget(name: "SegnoTransfer", dependencies: ["TransferCore"]),
    .testTarget(name: "TransferCoreTests", dependencies: ["TransferCore", "SegnoTransfer"]),
  ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RecoverRadar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RecoveryCore", type: .static, targets: ["RecoveryCore"]),
        .library(name: "RecoveryUI", type: .static, targets: ["RecoveryUI"]),
        .library(name: "COROSIntegration", type: .static, targets: ["COROSIntegration"])
    ],
    targets: [
        .target(name: "RecoveryCore"),
        .target(name: "RecoveryUI", dependencies: ["RecoveryCore"]),
        .target(name: "COROSIntegration", dependencies: ["RecoveryCore"]),
        .testTarget(name: "RecoveryCoreTests", dependencies: ["RecoveryCore"]),
        .testTarget(name: "COROSIntegrationTests", dependencies: ["COROSIntegration", "RecoveryCore"])
    ]
)

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Quota", platforms: [.macOS(.v14)],
    products: [
        .library(name: "QuotaCore", type: .static, targets: ["QuotaCore"]),
        .library(name: "QuotaUI", type: .static, targets: ["QuotaUI"]),
        .executable(name: "Quota", targets: ["QuotaApp"]),
        .executable(name: "QuotaRender", targets: ["QuotaRender"])
    ],
    targets: [
        .target(name: "QuotaCore"),
        .target(name: "QuotaUI", dependencies: ["QuotaCore"]),
        .executableTarget(name: "QuotaApp", dependencies: ["QuotaCore", "QuotaUI"]),
        .executableTarget(name: "QuotaRender", dependencies: ["QuotaCore", "QuotaUI"]),
        .testTarget(name: "QuotaCoreTests", dependencies: ["QuotaCore"]),
        .testTarget(name: "QuotaConnectionTests", dependencies: ["QuotaApp", "QuotaCore"])
    ], swiftLanguageVersions: [.v5]
)

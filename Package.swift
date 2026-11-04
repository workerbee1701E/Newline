// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Newline",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "Newline", targets: ["Newline"]), .library(name: "NewlineCore", targets: ["NewlineCore"])],
    dependencies: [.package(url: "https://github.com/swiftlang/swift-cmark.git", exact: "0.9.0")],
    targets: [
        .target(name: "NewlineCore", dependencies: [.product(name: "cmark-gfm", package: "swift-cmark"), .product(name: "cmark-gfm-extensions", package: "swift-cmark")]),
        .executableTarget(name: "Newline", dependencies: ["NewlineCore"]),
        .executableTarget(name: "NewlineChecks", dependencies: ["NewlineCore"], path: "Tests/NewlineCoreTests", exclude: ["AssetStoreTests.swift"])
    ],
    swiftLanguageModes: [.v5]
)

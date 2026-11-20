// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PhotoCull",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PhotoCull", targets: ["PhotoCullApp"]),
        .library(name: "PhotoCullCore", targets: ["PhotoCullCore"]),
        .library(name: "PhotoCullServer", targets: ["PhotoCullServer"]),
        // The Mac host behind the HTTP API: PhotoCullCore answers CullServer's questions.
        .library(name: "PhotoCullHost", targets: ["PhotoCullHost"]),
        .executable(name: "PhotoCullTests", targets: ["PhotoCullTests"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird", from: "2.0.0"),
        // Embedded lifecycle for the HTTP listener: start it, stop it programmatically.
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.0.0"),
    ],
    targets: [
        .target(name: "PhotoCullCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        // Remote-culling HTTP API. Deliberately independent of PhotoCullCore and of
        // AppKit/SwiftUI/ImageIO so it stays buildable on Linux later.
        .target(name: "PhotoCullServer",
                dependencies: [
                    .product(name: "Hummingbird", package: "hummingbird"),
                    .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                ],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        // The Mac host: the app's own library behind the HTTP API. Kept out of
        // PhotoCullServer so the server stays usable by a headless host later.
        .target(name: "PhotoCullHost",
                dependencies: ["PhotoCullCore", "PhotoCullServer"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "PhotoCullApp", dependencies: ["PhotoCullCore", "PhotoCullHost"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "PhotoCullTests", dependencies: ["PhotoCullCore"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)

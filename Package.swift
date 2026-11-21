// swift-tools-version:6.0
import PackageDescription

// The SwiftUI/AppKit app exists only on macOS. Core, Server and Host (and the
// tests) must also build on Linux, where a headless home server will use them.
#if os(macOS)
let appProducts: [Product] = [.executable(name: "PhotoCull", targets: ["PhotoCullApp"])]
let appTargets: [Target] = [
    .executableTarget(name: "PhotoCullApp", dependencies: ["PhotoCullCore", "PhotoCullHost"],
                      swiftSettings: [.swiftLanguageMode(.v5)]),
]
#else
let appProducts: [Product] = []
let appTargets: [Target] = []
#endif

let package = Package(
    name: "PhotoCull",
    platforms: [.macOS(.v14)],
    products: appProducts + [
        .library(name: "PhotoCullCore", targets: ["PhotoCullCore"]),
        .library(name: "PhotoCullServer", targets: ["PhotoCullServer"]),
        // The host behind the HTTP API: PhotoCullCore answers CullServer's questions.
        .library(name: "PhotoCullHost", targets: ["PhotoCullHost"]),
        // Headless host for a home server: the same API and PWA, own data root.
        .executable(name: "photocull-serve", targets: ["PhotoCullServe"]),
        .executable(name: "PhotoCullTests", targets: ["PhotoCullTests"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird", from: "2.0.0"),
        // Embedded lifecycle for the HTTP listener: start it, stop it programmatically.
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.0.0"),
    ],
    targets: [
        .target(name: "PhotoCullCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        // Remote-culling HTTP API. Independent of PhotoCullCore and of ImageIO,
        // so it builds everywhere.
        .target(name: "PhotoCullServer",
                dependencies: [
                    .product(name: "Hummingbird", package: "hummingbird"),
                    .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                ],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        // The host: a library behind the HTTP API. Kept out of PhotoCullServer so
        // the server stays usable by a headless host.
        .target(name: "PhotoCullHost",
                dependencies: ["PhotoCullCore", "PhotoCullServer"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        // The home-server host: PhotoCullCore's library behind CullServer, with its
        // own mode gate and data root instead of the Mac app's config. Built on
        // Linux and macOS; no AppKit, no SwiftUI.
        .executableTarget(name: "PhotoCullServe",
                          dependencies: ["PhotoCullCore", "PhotoCullHost", "PhotoCullServer"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "PhotoCullTests", dependencies: ["PhotoCullCore"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
    ] + appTargets
)

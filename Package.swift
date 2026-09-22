// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Gity",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Gity", targets: ["Gity"]),
    ],
    targets: [
        // Pure Swift git layer: process runner, parsers, models, file watching. No UI.
        .target(name: "GitKit"),
        // SwiftUI app. UI code is main-actor isolated by default, like new Xcode app templates.
        .executableTarget(
            name: "Gity",
            dependencies: ["GitKit"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "GitKitTests", dependencies: ["GitKit"]),
    ]
)

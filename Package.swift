// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TopDrop",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "TopDropCore", targets: ["TopDropCore"]),
        .executable(name: "TopDrop", targets: ["TopDropApp"]),
        .executable(name: "TopDropNotesWorker", targets: ["TopDropNotesWorker"]),
        .executable(name: "TopDropTests", targets: ["TopDropTests"]),
    ],
    targets: [
        .executableTarget(name: "TopDropNotesWorker", dependencies: ["TopDropCore"]),
        .executableTarget(name: "TopDropNotesWorkerFixture"),
        .target(
            name: "TopDropCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("Vision"),
                .linkedFramework("ImageIO"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreServices"),
                .linkedFramework("Security"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        .executableTarget(
            name: "TopDropApp",
            dependencies: ["TopDropCore"],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .executableTarget(
            name: "TopDropTests",
            dependencies: ["TopDropCore"],
            path: "Tests/TopDropCoreTests",
            resources: [
                .process("Fixtures")
            ]
        ),
    ]
)

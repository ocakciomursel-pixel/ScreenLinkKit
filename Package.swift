// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ScreenLinkKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ScreenLinkKit",
            targets: ["ScreenLinkKit"]
        ),
        .executable(
            name: "ScreenLinkDemo",
            targets: ["ScreenLinkDemo"]
        )
    ],
    targets: [
        .target(
            name: "ScreenLinkKit",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox")
            ]
        ),
        .executableTarget(
            name: "ScreenLinkDemo",
            dependencies: ["ScreenLinkKit"]
        ),
        .testTarget(
            name: "ScreenLinkKitTests",
            dependencies: ["ScreenLinkKit"]
        )
    ]
)

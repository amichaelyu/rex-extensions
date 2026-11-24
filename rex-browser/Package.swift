// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "rex-browser",
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(
            name: "rex-browser",
            path: "Sources/rex-browser",
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("WebKit"), .linkedFramework("ScreenCaptureKit"), .linkedFramework("VideoToolbox")]
        ),
    ]
)

// swift-tools-version:5.9
// S3DV Viewer — native macOS front-end for recorded .s3dv streams (research kit).
import PackageDescription

let package = Package(
    name: "S3DVViewer",
    platforms: [.macOS(.v13)],
    targets: [
        // Byte-compatible .s3dv reader mirrored from src/s3dv (protocol.py + container.py v0.1).
        .target(name: "S3DVCore", path: "Sources/S3DVCore"),
        // Line protocol + socket path shared by the app and the CLI.
        .target(name: "S3DVControl", path: "Sources/S3DVControl"),
        .executableTarget(
            name: "S3DVViewer",
            dependencies: ["S3DVCore", "S3DVControl"],
            path: "Sources/S3DVViewer",
            resources: [.copy("Resources")]
        ),
        // `s3dvctl`: drives a running viewer over its UNIX control socket.
        .executableTarget(
            name: "s3dvctl",
            dependencies: ["S3DVControl"],
            path: "Sources/s3dvctl"
        ),
        .testTarget(
            name: "S3DVCoreTests",
            dependencies: ["S3DVCore", "S3DVControl"],
            path: "Tests/S3DVCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)

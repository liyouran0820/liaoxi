// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ChatArchive",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ChatArchive", targets: ["ChatArchive"])
    ],
    targets: [
        .executableTarget(
            name: "ChatArchive",
            path: "AppSources/ChatArchive"
        ),
        .testTarget(
            name: "ChatArchiveTests",
            dependencies: ["ChatArchive"],
            path: "Tests/ChatArchiveTests"
        )
    ]
)

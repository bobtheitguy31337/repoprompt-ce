// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RepoPromptIrohTransport",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "RepoPromptIrohTransport", targets: ["RepoPromptIrohTransport"]),
    ],
    targets: [
        .binaryTarget(
            name: "IrohTransportFFI",
            path: "Artifacts/IrohTransportFFI.xcframework"
        ),
        .target(
            name: "RepoPromptIrohTransport",
            dependencies: ["IrohTransportFFI"],
            path: "Sources/RepoPromptIrohTransport",
            linkerSettings: [
                .linkedFramework("CoreWLAN", .when(platforms: [.macOS])),
                .linkedFramework("Network"),
                .linkedFramework("SystemConfiguration")
            ]
        ),
        .testTarget(
            name: "RepoPromptIrohTransportTests",
            dependencies: ["RepoPromptIrohTransport"],
            path: "Tests/RepoPromptIrohTransportTests"
        ),
    ]
)

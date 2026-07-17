// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Emacs",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "Emacs", type: .dynamic, targets: ["Emacs"])
    ],
    dependencies: [
        .package(url: "https://github.com/osaurus-ai/osaurus-plugin-sdk.git", exact: "1.0.0")
    ],
    targets: [
        .target(
            name: "Emacs",
            dependencies: [
                .product(name: "OsaurusPluginKit", package: "osaurus-plugin-sdk")
            ],
            path: "Sources/Emacs"
        ),
        .testTarget(
            name: "EmacsTests",
            dependencies: [
                "Emacs",
                .product(name: "OsaurusPluginKit", package: "osaurus-plugin-sdk"),
            ],
            path: "Tests/EmacsTests"
        )
    ]
)

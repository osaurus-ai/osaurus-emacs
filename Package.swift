// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Emacs",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "Emacs", type: .dynamic, targets: ["Emacs"])
    ],
    targets: [
        .target(
            name: "Emacs",
            path: "Sources/Emacs"
        ),
        .testTarget(
            name: "EmacsTests",
            dependencies: ["Emacs"],
            path: "Tests/EmacsTests"
        )
    ]
)
// swift-tools-version:6.0
import PackageDescription

// Platform-independent pieces of the iOS app. Everything here builds and tests on
// Linux so keyboard encoding, config parsing, vault crypto and the SSH layer can be
// exercised without Xcode. The app target in ios/ depends on this package by path.
let package = Package(
    name: "TubeKit",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [
        .library(name: "TermInput", targets: ["TermInput"]),
        .library(name: "TubeCore", targets: ["TubeCore"]),
        .library(name: "TubeSSH", targets: ["TubeSSH"]),
        .library(name: "TubeSync", targets: ["TubeSync"]),
    ],
    dependencies: [
        // 0.12.1 switched swift-nio-ssh to an unvetted personal fork; stay on 0.12.0.
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.12.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.12.3"..<"4.0.0"),
    ],
    targets: [
        .target(name: "TermInput"),
        .target(
            name: "TubeCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "TubeSSH",
            dependencies: [
                "TubeCore",
                .product(name: "Citadel", package: "Citadel"),
            ]
        ),
        .target(
            name: "TubeSync",
            dependencies: [
                "TubeCore",
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(name: "TermInputTests", dependencies: ["TermInput"]),
        .testTarget(name: "TubeCoreTests", dependencies: ["TubeCore"]),
        .testTarget(name: "TubeSSHTests", dependencies: ["TubeSSH", "TermInput"]),
        .testTarget(name: "TubeSyncTests", dependencies: ["TubeSync"]),
    ],
    swiftLanguageModes: [.v5]
)

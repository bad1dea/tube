// swift-tools-version:6.0
import PackageDescription

// Platform-independent pieces of the iOS app. Everything here builds and tests on
// Linux so keyboard encoding, config parsing, vault crypto and the SSH layer can be
// exercised without Xcode. The app target in ios/ depends on this package by path.
let package = Package(
    name: "ConchKit",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [
        .library(name: "TermInput", targets: ["TermInput"]),
        .library(name: "ConchCore", targets: ["ConchCore"]),
        .library(name: "ConchSSH", targets: ["ConchSSH"]),
        .library(name: "ConchSync", targets: ["ConchSync"]),
    ],
    dependencies: [
        // 0.12.1 switched swift-nio-ssh to an unvetted personal fork; stay on 0.12.0.
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.12.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.12.3"..<"4.0.0"),
    ],
    targets: [
        .target(name: "TermInput"),
        .target(
            name: "ConchCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "ConchSSH",
            dependencies: [
                "ConchCore",
                .product(name: "Citadel", package: "Citadel"),
            ]
        ),
        .target(
            name: "ConchSync",
            dependencies: [
                "ConchCore",
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(name: "TermInputTests", dependencies: ["TermInput"]),
        .testTarget(name: "ConchCoreTests", dependencies: ["ConchCore"]),
        .testTarget(name: "ConchSSHTests", dependencies: ["ConchSSH", "TermInput"]),
        .testTarget(name: "ConchSyncTests", dependencies: ["ConchSync"]),
    ],
    swiftLanguageModes: [.v5]
)

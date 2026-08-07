// swift-tools-version: 6.0
//
// The Linux-port package: builds the server-facing subset of StacksCore with
// plain `swift build` (macOS + Linux arm64/x86_64). Apple-only components
// (MTP devices, ImageIO cover thumbnailing, Calibre/Mobi/Import/Enrichment
// client features, Bonjour via Network.framework) are EXCLUDED — the server
// ingests commands from clients and never runs those paths. The macOS app
// keeps building the full core via XcodeGen; this package is the headless
// `stacks` surface.
import PackageDescription

let package = Package(
    name: "StacksCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "StacksCore", targets: ["StacksCore"]),
        .executable(name: "stacks", targets: ["StacksServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.26.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
    ],
    targets: [
        .target(
            name: "StacksCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "StacksCore",
            // Apple-only / client-only code the headless server never runs.
            exclude: [
                "MobiImport",
                "Import",
                "Enrichment",
                "Devices",
                "Vendored",
                "Library/CoverThumbnailer.swift",
                // macOS sandbox bookmarking (security-scoped URLs); the
                // headless server opens libraries by path argument.
                "Security",
            ]
        ),
        .executableTarget(
            name: "StacksServer",
            dependencies: [
                "StacksCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "StacksServer"
        ),
        .testTarget(
            name: "StacksCoreTests",
            dependencies: [
                "StacksCore",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            path: "StacksCoreTests",
            // Mirrors the core target's excludes: tests referencing excluded
            // client features (Calibre/Mobi/Import/Enrichment/Devices) and
            // macOS-only surfaces (BonjourTests uses Network.framework).
            exclude: [
                "MobiImport",
                "Import",
                "Enrichment",
                "Devices",
                "Security",
                "Selection",
                "Library/LibraryRepositoryTests.swift",
                "Library/CoverThumbnailerTests.swift",
                "Library/BookFolderTests.swift",
                "Server/BonjourTests.swift",
            ]
        ),
    ]
)

// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LibtorrentKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "LibtorrentKit", targets: ["LibtorrentKit"]),
    ],
    targets: [
        .binaryTarget(
            name: "LibtorrentNative",
            url: "https://github.com/WhoSayIn/LibtorrentKit/releases/download/v0.3.0/LibtorrentNative.xcframework.zip",
            checksum: "8f6df6c602d528cca58a87697fea74905453a650501feecf4bd60afc4ea02b7b"
        ),
        .binaryTarget(
            name: "OpenSSL",
            url: "https://github.com/krzyzanowskim/OpenSSL/releases/download/3.6.3000/OpenSSL.xcframework.zip",
            checksum: "6c4b064d12b8de2ae77ac59fbcbbd1c20b4fecfb7fc50b8ab326347c52ecbf0c"
        ),
        .target(
            name: "LibtorrentKit",
            dependencies: ["LibtorrentNative", "OpenSSL"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .testTarget(
            name: "LibtorrentKitTests",
            dependencies: ["LibtorrentKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ],
    cxxLanguageStandard: .cxx17
)

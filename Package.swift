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
            url: "https://github.com/WhoSayIn/LibtorrentKit/releases/download/v0.2.0/LibtorrentNative.xcframework.zip",
            checksum: "bd9d2ba2726aaf446cc9e4d85c2c1f5738c641996e4b87aff36ba336cb608784"
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

// swift-tools-version: 6.0

import PackageDescription
import Foundation

// Rebuild with Scripts/build-xcframework.sh before exercising native changes.
let useLocalNative = ProcessInfo.processInfo.environment["LIBTORRENTKIT_USE_LOCAL_NATIVE"] == "1"

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
        useLocalNative ? .binaryTarget(
            name: "LibtorrentNative",
            path: "Vendor/LibtorrentNative.xcframework"
        ) : .binaryTarget(
            name: "LibtorrentNative",
            url: "https://github.com/WhoSayIn/LibtorrentKit/releases/download/v0.5.1/LibtorrentNative.xcframework.zip",
            checksum: "418689f38e68f1fe324576b5482a55dd8338a72ee1d249103acde480bc7dce94"
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

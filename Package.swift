// swift-tools-version:5.1
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription

let package = Package(
    name: "HaishinKit",
    platforms: [
        .iOS(.v11),
        .tvOS(.v11),
        .macOS(.v10_13)
    ],
    products: [
        .library(name: "HaishinKit", targets: ["HaishinKit"])
    ],
    dependencies: [
        
    ],
    targets: [
        .target(name: "HaishinKit",
                dependencies: [],
                path: "Sources",
                sources: [
                    "Codec",
                    "Extension",
                    "FLV",
                    "HTTP",
                    "ISO",
                    "Media",
                    "MP4",
                    "Net",
                    "RTMP",
                    "Util",
                    "Platforms",
                    "TS"
                ])
    ]
)

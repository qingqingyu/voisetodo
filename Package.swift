// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceTodoProtocols",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)  // 添加 macOS 支持以便命令行编译验证
    ],
    products: [
        .library(
            name: "VoiceTodoProtocols",
            targets: ["VoiceTodoProtocols"]),
    ],
    targets: [
        .target(
            name: "VoiceTodoProtocols",
            path: "Protocols",
            exclude: ["CodingConventions.md"]),
        .testTarget(
            name: "VoiceTodoProtocolsTests",
            dependencies: ["VoiceTodoProtocols"],
            path: "VoiceTodoTests/Protocols"),
    ]
)

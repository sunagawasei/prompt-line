// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PromptLine",
    platforms: [.macOS(.v14)],
    targets: [
        // UI に依存しない純粋なロジック(履歴・下書き)。単体テストはここに置く
        .target(name: "PromptLineCore"),
        .executableTarget(name: "PromptLine", dependencies: ["PromptLineCore"]),
        // 表示遅延・メモリの計測ハーネス(Electron 版との比較用)
        .executableTarget(name: "bench"),
        .testTarget(name: "PromptLineCoreTests", dependencies: ["PromptLineCore"]),
    ],
    swiftLanguageModes: [.v5]
)

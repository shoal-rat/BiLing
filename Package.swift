// swift-tools-version: 6.2
import PackageDescription

// llama.cpp and ggml come from Homebrew (`brew install llama.cpp`). The
// installer copies the dylibs into the app bundle and rewrites their paths.
let llamaInclude = "/opt/homebrew/opt/llama.cpp/include"
let ggmlInclude = "/opt/homebrew/opt/ggml/include"
let llamaLib = "/opt/homebrew/opt/llama.cpp/lib"
let ggmlLib = "/opt/homebrew/opt/ggml/lib"

let package = Package(
    name: "Zhiyin",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "ZhiyinCore", targets: ["ZhiyinCore"]),
        .library(name: "ZhiyinListener", targets: ["ZhiyinListener"]),
        .executable(name: "Zhiyin", targets: ["ZhiyinIME"]),
        .executable(name: "tiaoyin", targets: ["Tiaoyin"]),
    ],
    targets: [
        // 弦 strings, 琴谱 score, 默契 rapport, and how candidates are composed.
        .target(name: "ZhiyinCore"),
        .target(
            name: "CLlama",
            cSettings: [.unsafeFlags(["-I\(llamaInclude)", "-I\(ggmlInclude)"])]
        ),
        // 子期 the listener: constrained beam search over the fine-tuned model.
        .target(
            name: "ZhiyinListener",
            dependencies: ["ZhiyinCore", "CLlama"],
            swiftSettings: [.unsafeFlags(["-Xcc", "-I\(llamaInclude)", "-Xcc", "-I\(ggmlInclude)"])],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(llamaLib)", "-L\(ggmlLib)",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", llamaLib,
                    "-Xlinker", "-rpath", "-Xlinker", ggmlLib,
                ]),
                .linkedLibrary("llama"),
                .linkedLibrary("ggml"),
                .linkedLibrary("ggml-base"),
                .linkedFramework("Accelerate"),
            ]
        ),
        // 知音.app — the InputMethodKit input method, its panel and 琴台.
        .executableTarget(
            name: "ZhiyinIME",
            dependencies: ["ZhiyinCore", "ZhiyinListener"],
            swiftSettings: [.unsafeFlags(["-Xcc", "-I\(llamaInclude)", "-Xcc", "-I\(ggmlInclude)"])],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("InputMethodKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        // 调音 · tuning: the command-line tool for conversion, evaluation, benchmarks.
        .executableTarget(
            name: "Tiaoyin",
            dependencies: ["ZhiyinCore", "ZhiyinListener"],
            swiftSettings: [.unsafeFlags(["-Xcc", "-I\(llamaInclude)", "-Xcc", "-I\(ggmlInclude)"])]
        ),
        .testTarget(
            name: "ZhiyinCoreTests",
            dependencies: ["ZhiyinCore"],
            swiftSettings: [.unsafeFlags(["-Xcc", "-I\(llamaInclude)", "-Xcc", "-I\(ggmlInclude)"])]
        ),
    ],
    swiftLanguageModes: [.v5]
)

// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BiLing",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "PinyinLattice", targets: ["PinyinLattice"]),
        .library(name: "InputSessionCore", targets: ["InputSessionCore"]),
        .library(name: "BackboneEngine", targets: ["BackboneEngine"]),
        .library(name: "IPCProtocol", targets: ["IPCProtocol"]),
        .library(name: "LLMRanker", targets: ["LLMRanker"]),
        .executable(name: "biling-cli", targets: ["BiLingCLI"]),
        .executable(name: "biling-engined", targets: ["BiLingEngine"]),
        .executable(name: "BiLingApp", targets: ["BiLingApp"]),
    ],
    targets: [
        .target(name: "PinyinLattice"),
        .target(name: "InputSessionCore"),
        .systemLibrary(name: "CSQLite"),
        .target(
            name: "BackboneEngine",
            dependencies: ["PinyinLattice", "CSQLite"],
            resources: [.copy("Resources/lexicon.sqlite3")]
        ),
        .target(name: "IPCProtocol"),
        .target(
            name: "CLlamaBridge",
            path: "Sources/CLlamaBridge",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags([
                    "-I/opt/homebrew/opt/llama.cpp/include",
                    "-I/opt/homebrew/opt/ggml/include",
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L/opt/homebrew/opt/llama.cpp/lib",
                    "-L/opt/homebrew/opt/ggml/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "/opt/homebrew/opt/llama.cpp/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "/opt/homebrew/opt/ggml/lib",
                ]),
                .linkedLibrary("llama"),
                .linkedLibrary("ggml"),
            ]
        ),
        .target(
            name: "LLMRanker",
            dependencies: ["CLlamaBridge", "BackboneEngine", "IPCProtocol"]
        ),
        .executableTarget(
            name: "BiLingCLI",
            dependencies: ["BackboneEngine", "LLMRanker"]
        ),
        .executableTarget(
            name: "BiLingEngine",
            dependencies: ["IPCProtocol", "LLMRanker"]
        ),
        .executableTarget(
            name: "BiLingApp",
            dependencies: ["BackboneEngine", "InputSessionCore", "IPCProtocol"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("InputMethodKit"),
            ]
        ),
        .testTarget(
            name: "PinyinLatticeTests",
            dependencies: ["PinyinLattice"]
        ),
        .testTarget(
            name: "BackboneEngineTests",
            dependencies: ["BackboneEngine"]
        ),
        .testTarget(
            name: "InputSessionCoreTests",
            dependencies: ["InputSessionCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)

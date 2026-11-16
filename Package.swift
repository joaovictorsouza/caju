// swift-tools-version: 6.2
//
// Manifesto do Caju. TRANCADO: mudanças aqui vão em PR dedicado e curto
// (CLAUDE.md, docs/standards/pr-e-revisao.md). Os targets abaixo seguem o mapa
// de camadas do plano (§5): dependências só para baixo.
import CompilerPluginSupport
import PackageDescription

/// Configurações comuns a todos os targets: Swift 6 (concorrência estrita) e
/// avisos como erro (docs/standards/codigo-swift.md).
let common: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .treatAllWarnings(as: .error),
]

/// Declara um módulo da engine; `README.md` do módulo fica fora do alvo.
func module(_ name: String, _ dependencies: [Target.Dependency]) -> Target {
    .target(
        name: name,
        dependencies: dependencies,
        exclude: ["README.md"],
        swiftSettings: common
    )
}

/// O build cruzado para Android (swift-android-action) define `TARGET_OS_ANDROID`. Lá os testes da macro
/// não rodam (a macro é do host) e compilá-los com `swift-syntax` + XCTest quebra o índice do compilador
/// ("Failed opening .../index/store/...", ADR 0030): ficam de fora desse build.
let macroTests: [Target] =
    Context.environment["TARGET_OS_ANDROID"] == nil
    ? [
        .testTarget(
            name: "CajuMacrosPluginTests",
            dependencies: [
                "CajuMacrosPlugin",
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ],
            swiftSettings: common
        )
    ] : []

let package = Package(
    name: "Caju",
    // iOS 17 e macOS 14 (par do iOS 17); Android API 29 vem pelo Swift SDK for Android (ADR 0007).
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CajuMath", targets: ["CajuMath"]),
        .library(name: "CajuCore", targets: ["CajuCore"]),
        .library(name: "CajuCollections", targets: ["CajuCollections"]),
        .library(name: "CajuAssetsCore", targets: ["CajuAssetsCore"]),
        .library(name: "CajuText", targets: ["CajuText"]),
        .library(name: "CajuUILayout", targets: ["CajuUILayout"]),
        .library(name: "CajuPhysicsSpatial", targets: ["CajuPhysicsSpatial"]),
        .library(name: "CajuPlatform", targets: ["CajuPlatform"]),
        .library(name: "CajuRHI", targets: ["CajuRHI"]),
        .library(name: "CajuRHIMetal", targets: ["CajuRHIMetal"]),
        .library(name: "CajuRHIVulkan", targets: ["CajuRHIVulkan"]),
        .library(name: "CajuRHIConformance", targets: ["CajuRHIConformance"]),
        .library(name: "CajuScene", targets: ["CajuScene"]),
        .library(name: "CajuInput", targets: ["CajuInput"]),
        .library(name: "CajuRender", targets: ["CajuRender"]),
        .library(name: "CajuAssets", targets: ["CajuAssets"]),
        .library(name: "CajuAnim", targets: ["CajuAnim"]),
        .library(name: "CajuAudio", targets: ["CajuAudio"]),
        .library(name: "CajuUI", targets: ["CajuUI"]),
        .library(name: "CajuPhysics", targets: ["CajuPhysics"]),
        .library(name: "CajuNet", targets: ["CajuNet"]),
        .library(name: "CajuTesting", targets: ["CajuTesting"]),
        .library(name: "CajuScripting", targets: ["CajuScripting"]),
        .executable(name: "caju-bench", targets: ["CajuBenchmarks"]),
        .executable(name: "caju-tools", targets: ["CajuTools"]),
    ],
    dependencies: [
        // Só para a macro @Component (roda no host, não entra no binário do jogo; ADR 0030).
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "602.0.0")
    ],
    targets: [
        // Plugin de macros (compilado para o host). Sem README no alvo: ver Sources/CajuCore/README.md.
        .macro(
            name: "CajuMacrosPlugin",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ],
            swiftSettings: common
        ),

        // Camada 0 (puros)
        module("CajuMath", []),
        module("CajuCore", ["CajuMacrosPlugin"]),
        module("CajuCollections", []),
        // Camada 1 (puros)
        module("CajuAssetsCore", ["CajuMath", "CajuCollections"]),
        module("CajuText", ["CajuMath", "CajuCollections"]),
        module("CajuUILayout", ["CajuMath", "CajuCollections"]),
        module("CajuPhysicsSpatial", ["CajuMath", "CajuCollections"]),
        // Camada 2 (plataforma e GPU)
        module(
            "CajuPlatform",
            ["CajuCore", .target(name: "CVulkan", condition: .when(platforms: [.android]))]
        ),
        module("CajuRHI", ["CajuCore", "CajuMath"]),
        module("CajuRHIMetal", ["CajuRHI"]),
        // Vulkan só existe no Android: o CVulkan (system library) é condicional.
        module(
            "CajuRHIVulkan",
            [
                "CajuRHI", .target(name: "CVulkan", condition: .when(platforms: [.android])),
                .target(name: "CVMA", condition: .when(platforms: [.android])),
            ]
        ),
        // Suíte de conformidade do RHI, genérica no dispositivo: roda no Metal (testes) e no Vulkan (aparelho).
        module("CajuRHIConformance", ["CajuRHI", "CajuMath"]),
        // Camada 3
        module("CajuScene", ["CajuCore", "CajuMath"]),
        module("CajuInput", ["CajuCore", "CajuMath", "CajuPlatform"]),
        module("CajuRender", ["CajuCore", "CajuMath", "CajuRHI", "CajuScene", "CajuAssets"]),
        module("CajuAssets", ["CajuCore", "CajuAssetsCore"]),
        module("CajuToolsCore", []),
        module("CajuAnim", ["CajuCore", "CajuMath", "CajuScene"]),
        module("CajuAudio", ["CajuCore", "CajuMath", "CMiniaudio"]),
        module("CajuUI", ["CajuCore", "CajuUILayout", "CajuText", "CajuRHI", "CajuInput"]),
        module("CajuPhysics", ["CajuCore", "CajuPhysicsSpatial", "CajuScene"]),
        // Camada 4
        module("CajuNet", ["CajuCore"]),
        module("CajuTesting", ["CajuCore"]),
        module("CajuScripting", ["CajuCore"]),

        // Cabeçalhos Vulkan/NDK do sistema (só Android; Sources/CVulkan).
        .systemLibrary(name: "CVulkan"),

        // miniaudio 0.11.26 vendorizado (ADR 0005; versão e hash em Sources/CMiniaudio/VERSION).
        // Só o CajuAudio depende dele. Sem README.md exigido: é código de terceiros.
        .target(
            name: "CMiniaudio",
            exclude: ["README.md", "LICENSE", "VERSION"],
            publicHeadersPath: "include",
            cSettings: [.define("MA_NO_ENCODING")]
        ),

        // Vulkan Memory Allocator 3.5.0 vendorizado (ADR 0005, ADR 0024; versão e hash em Sources/CVMA/VERSION).
        // Só o CajuRHIVulkan depende dele, e só no Android (no host o módulo compila vazio).
        .target(
            name: "CVMA",
            exclude: ["README.md", "LICENSE", "VERSION"],
            publicHeadersPath: "include"
        ),

        // Ferramentas
        .executableTarget(
            name: "CajuTools",
            dependencies: ["CajuToolsCore"],
            exclude: ["README.md"],
            swiftSettings: common
        ),
        .executableTarget(
            name: "CajuBenchmarks",
            dependencies: [
                "CajuMath", "CajuCore", "CajuUILayout", "CajuPhysicsSpatial", "CajuScene", "CajuAssets",
                "CajuRender",
            ],
            swiftSettings: common
        ),

        // Testes
        .testTarget(
            name: "CajuMathTests",
            dependencies: ["CajuMath", "CajuTesting"],
            swiftSettings: common
        ),
        .testTarget(
            name: "CajuAssetsTests",
            dependencies: ["CajuAssets", "CajuAssetsCore", "CajuCore", "CajuTesting"],
            swiftSettings: common
        ),
        .testTarget(
            name: "CajuToolsTests",
            dependencies: ["CajuToolsCore"],
            swiftSettings: common
        ),
        .testTarget(
            name: "CajuAssetsCoreTests",
            dependencies: ["CajuAssetsCore", "CajuMath", "CajuTesting"],
            swiftSettings: common
        ),
        .testTarget(
            name: "CajuCoreTests",
            dependencies: ["CajuCore", "CajuTesting"],
            swiftSettings: common
        ),
        .testTarget(
            name: "CajuSceneTests",
            dependencies: ["CajuScene", "CajuCore", "CajuMath", "CajuTesting"],
            swiftSettings: common
        ),
        .testTarget(
            name: "CajuTextTests",
            dependencies: ["CajuText", "CajuMath", "CajuTesting"],
            swiftSettings: common
        ),
        .testTarget(
            name: "CajuUILayoutTests",
            dependencies: ["CajuUILayout", "CajuMath", "CajuTesting"],
            swiftSettings: common
        ),
        .testTarget(
            name: "CajuPhysicsSpatialTests",
            dependencies: ["CajuPhysicsSpatial", "CajuMath", "CajuTesting"],
            swiftSettings: common
        ),
        .testTarget(
            name: "CajuPlatformTests",
            dependencies: ["CajuPlatform"],
            swiftSettings: common
        ),
        .testTarget(
            name: "CajuRHIVulkanTests",
            dependencies: ["CajuRHIVulkan"],
            swiftSettings: common
        ),
        .testTarget(
            name: "CajuTestingTests",
            dependencies: ["CajuTesting"],
            swiftSettings: common
        ),
        // Garante que todos os módulos declarados compilam e linkam em conjunto.
        .testTarget(
            name: "CajuModulesTests",
            dependencies: [
                "CajuMath", "CajuCore", "CajuCollections", "CajuAssetsCore", "CajuText", "CajuUILayout",
                "CajuPhysicsSpatial", "CajuPlatform", "CajuRHI", "CajuRHIMetal", "CajuRHIVulkan",
                "CajuRHIConformance", "CajuScene", "CajuInput", "CajuRender", "CajuAssets", "CajuAnim",
                "CajuAudio", "CajuUI", "CajuPhysics", "CajuNet", "CajuTesting", "CajuScripting", "CMiniaudio",
            ],
            swiftSettings: common
        ),
    ] + macroTests
)

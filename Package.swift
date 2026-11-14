// swift-tools-version: 6.2
//
// Manifesto do Caju. TRANCADO: mudanças aqui vão em PR dedicado e curto
// (CLAUDE.md, docs/standards/pr-e-revisao.md). Os targets abaixo seguem o mapa
// de camadas do plano (§5): dependências só para baixo.
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
    ],
    targets: [
        // Camada 0 (puros)
        module("CajuMath", []),
        module("CajuCore", []),
        module("CajuCollections", []),
        // Camada 1 (puros)
        module("CajuAssetsCore", ["CajuMath", "CajuCollections"]),
        module("CajuText", ["CajuMath", "CajuCollections"]),
        module("CajuUILayout", ["CajuMath", "CajuCollections"]),
        module("CajuPhysicsSpatial", ["CajuMath", "CajuCollections"]),
        // Camada 2 (plataforma e GPU)
        module("CajuPlatform", ["CajuCore", .target(name: "CVulkan", condition: .when(platforms: [.android]))]),
        module("CajuRHI", ["CajuCore", "CajuMath"]),
        module("CajuRHIMetal", ["CajuRHI"]),
        // Vulkan só existe no Android: o CVulkan (system library) é condicional.
        module("CajuRHIVulkan", ["CajuRHI", .target(name: "CVulkan", condition: .when(platforms: [.android]))]),
        // Camada 3
        module("CajuScene", ["CajuCore", "CajuMath"]),
        module("CajuInput", ["CajuCore", "CajuMath", "CajuPlatform"]),
        module("CajuRender", ["CajuCore", "CajuMath", "CajuRHI", "CajuScene"]),
        module("CajuAssets", ["CajuCore", "CajuAssetsCore", "CajuRHI"]),
        module("CajuAnim", ["CajuCore", "CajuMath", "CajuScene"]),
        module("CajuAudio", ["CajuCore", "CajuMath"]),
        module("CajuUI", ["CajuCore", "CajuUILayout", "CajuText", "CajuRHI", "CajuInput"]),
        module("CajuPhysics", ["CajuCore", "CajuPhysicsSpatial", "CajuScene"]),
        // Camada 4
        module("CajuNet", ["CajuCore"]),
        module("CajuTesting", ["CajuCore"]),
        module("CajuScripting", ["CajuCore"]),

        // Cabeçalhos Vulkan/NDK do sistema (só Android; Sources/CVulkan).
        .systemLibrary(name: "CVulkan"),

        // Ferramentas
        .executableTarget(
            name: "CajuBenchmarks",
            dependencies: ["CajuMath"],
            swiftSettings: common
        ),

        // Testes
        .testTarget(
            name: "CajuMathTests",
            dependencies: ["CajuMath", "CajuTesting"],
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
                "CajuPhysicsSpatial", "CajuPlatform", "CajuRHI", "CajuRHIMetal", "CajuRHIVulkan", "CajuScene",
                "CajuInput", "CajuRender", "CajuAssets", "CajuAnim", "CajuAudio", "CajuUI", "CajuPhysics",
                "CajuNet", "CajuTesting", "CajuScripting",
            ],
            swiftSettings: common
        ),
    ]
)

// swift-tools-version: 6.2
// Host Android do Caju: biblioteca dinâmica carregada pela NativeActivity.
// Pacote independente do Package.swift raiz (trancado); depende dele por caminho.
import PackageDescription

let package = Package(
    name: "CajuAndroidHost",
    products: [
        .library(name: "CajuAndroidHost", type: .dynamic, targets: ["CajuAndroidHost"]),
        .executable(name: "caju-conformance", targets: ["CajuConformanceRunner"]),
    ],
    dependencies: [
        .package(name: "Caju", path: "../..")
    ],
    targets: [
        .target(
            name: "CajuAndroidHost",
            dependencies: [
                .product(name: "CajuPlatform", package: "Caju"),
                .product(name: "CajuRHI", package: "Caju"),
                .product(name: "CajuRHIVulkan", package: "Caju"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6), .treatAllWarnings(as: .error)]
        ),
        // Suíte de conformidade do RHI no Vulkan, sem janela (`adb shell`); ver scripts/run-conformance.sh.
        .executableTarget(
            name: "CajuConformanceRunner",
            dependencies: [
                .product(name: "CajuRHIVulkan", package: "Caju"),
                .product(name: "CajuRHIConformance", package: "Caju"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6), .treatAllWarnings(as: .error)]
        ),
    ]
)

# CajuRHIConformance

Suíte de conformidade do RHI, **genérica no dispositivo** (ADR 0015, ADR 0024). Os mesmos casos e os mesmos valores esperados rodam em todo backend; é o critério "goldens iguais em Metal e Vulkan" da Onda 1.

- **Camada:** 2 (depende só de `CajuRHI` e `CajuMath`). Não usa `Testing`/XCTest: `CajuRHIConformance.run(_:)` devolve um `CajuConformanceReport`.
- **Trilha dona:** V-1.
- **Backend:** implementa `CajuConformanceBackend` (dispositivo, shaders do triângulo e leitura de pixels). O Metal o faz em `Tests/CajuModulesTests/CajuMetalTests.swift`; o Vulkan, no executável de conformidade em `Hosts/Android` (roda por `adb shell`, sem janela).
- **Casos:** triângulo de 1 amostra (fundo, centro, ápice, cobertura), MSAA 4x resolvido, *culling* e sentido do vértice (NDC com y para cima, origem da textura no canto superior esquerdo), upload/leitura de textura, erros de validação iguais aos do `CajuNullDevice`, handles destruídos.
- **Convenção para o Vulkan:** o backend inverte o viewport (altura negativa) para casar com o Metal; a suíte falha se não o fizer.

## Como testar
`swift test --filter CajuMetalConformanceTests` (Mac). No Android: `Hosts/Android/README.md`.

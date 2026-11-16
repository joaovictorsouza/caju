# Host iOS/macOS

App mínimo (SwiftUI) que consome o pacote; ponto de partida do host de plataforma (TB-2).

```sh
brew install xcodegen
cd Hosts/Apple && xcodegen generate
xcodebuild -project CajuHost.xcodeproj -scheme CajuHost-macOS build
xcodebuild -project CajuHost.xcodeproj -scheme CajuHost-iOS -destination 'generic/platform=iOS Simulator' build
```

## Demo M2
Cubo iluminado (MSAA 4x e profundidade `memoryless`, resolvido no backbuffer) e botão "GIRAR CUBO" com fonte bitmap simples (o texto real é da trilha CajuText). O toque no botão alterna a rotação.

## Shaders
`Shaders/demo.slang` é compilado offline para MSL por `Shaders/compile-shaders.sh` (precisa do `slangc`; testado com 2026.8). Gera um `.metal` por ponto de entrada em `Shaders/Generated/` (versionado, determinístico); o Xcode compila esses arquivos no `default.metallib` do app. O `slangc` 2026.8 perde os uniformes do estágio de vértice quando vários pontos de entrada saem juntos, por isso um arquivo por entrada. Bindings: `cubeUniforms` = `buffer(0)`, `uiUniforms` = `buffer(1)`, `atlas` = `texture(0)`, sampler `0`.

## Simulador
```sh
xcodebuild -project CajuHost.xcodeproj -scheme CajuHost-iOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/cajuhost-dd build CODE_SIGNING_ALLOWED=NO
```
Depois `xcrun simctl install`/`launch dev.caju.host`.

**Estado:** verificado no simulador iPhone 17 Pro (cubo e texto "GIRAR CUBO" renderizam). **Verificado no iPhone 16 Pro (S-0, `docs/evidencias/s0-ios/`):** toque, 50 ciclos de superfície, soak de 5 min e background/resume reais. Argumentos de lançamento: `-caju-gate` (mede e grava `Documents/gate.log`) e `-caju-soak-frames N`. No iOS o toque usa o espaço de coordenadas global (o local começa na área segura).

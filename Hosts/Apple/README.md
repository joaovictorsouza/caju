# Host iOS/macOS

App mínimo (SwiftUI) que consome o pacote; ponto de partida do host de plataforma (TB-2).

```sh
brew install xcodegen
cd Hosts/Apple && xcodegen generate
xcodebuild -project CajuHost.xcodeproj -scheme CajuHost-macOS build
xcodebuild -project CajuHost.xcodeproj -scheme CajuHost-iOS -destination 'generic/platform=iOS Simulator' build
```

**Estado:** o código foi escrito no M0 sem Xcode disponível na sessão; a validação é o job `apple-host` do CI (experimental até a primeira execução verde).

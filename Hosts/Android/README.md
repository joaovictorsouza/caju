# Host Android

APK mínimo (NativeActivity, sem código Java) que carrega `libCajuAndroidHost.so`, escrita em Swift, e desenha um triângulo em Vulkan na Game Thread. Decisões: [ADR 0019](../../docs/adr/0019-host-android-build-e-link.md), [ADR 0008](../../docs/adr/0008-android-game-thread.md).

## Requisitos (Mac)
- Swift 6.2+ e o **Swift SDK for Android** da mesma versão do toolchain (`swift sdk list`).
- **Android NDK r30** em `~/Library/Android/sdk/ndk/30.*` (ou `ANDROID_NDK_HOME`), Android SDK (platform 36, build-tools), JDK 17+.
- `glslc` só para regenerar o SPIR-V (`scripts/compile-shaders.sh`).
- Aparelho com depuração USB (referência: Galaxy S22+, Vulkan 1.1).

```sh
swift sdk install https://download.swift.org/swift-6.4.2-release/android-sdk/swift-6.4.2-RELEASE/swift-6.4.2-RELEASE_android.artifactbundle.tar.gz \
  --checksum 4d6ad63ea74becd58e123ff58b1b48c3be5ec0db0dff0ea5abe37ac007dd3233
sh "$(ls -d ~/Library/org.swift.swiftpm/swift-sdks/*android*/swift-android/scripts/setup-android-sdk.sh)"   # liga o NDK ao SDK
```

### Toolchain open-source (necessário para `swift build` no Android)
O toolchain do Xcode não traz `swift-autolink-extract`, e `swift build --swift-sdk aarch64-unknown-linux-android29 --product ...` falha no passo de link. Instale o toolchain de swift.org da mesma versão do SDK (6.4.2; sem sudo, o Xcode fica intacto):
```sh
curl -fLO https://download.swift.org/swift-6.4.2-release/xcode/swift-6.4.2-RELEASE/swift-6.4.2-RELEASE-osx.pkg
pkgutil --check-signature swift-6.4.2-RELEASE-osx.pkg   # Developer ID Installer: Swift Open Source
installer -pkg swift-6.4.2-RELEASE-osx.pkg -target CurrentUserHomeDirectory   # instala em ~/Library/Developer/Toolchains
export TOOLCHAINS=org.swift.642202610261a   # CFBundleIdentifier do .xctoolchain instalado
export ANDROID_NDK_HOME=~/Library/Android/sdk/ndk/30.0.15729638
swift build -c release --swift-sdk aarch64-unknown-linux-android29 --product caju-bench   # passa (verificado em 2026-11-15)
```
Sem esse toolchain, o contorno é compilar os objetos (`--target`) e ligar à mão, como em `scripts/build-native.sh` e em `docs/evidencias/s0-android/scripts/build-bench-android.sh` (PR #23).

## Gerar, instalar e rodar
```sh
cd Hosts/Android
./gradlew :app:assembleDebug        # chama scripts/build-native.sh (Swift → .so + runtime em jniLibs)
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n dev.caju.host/android.app.NativeActivity
adb logcat -s Caju                  # ciclo de vida: criada/ativo/inativo/destruída
adb exec-out screencap -p > print.png
```
Se `adb install -r` falhar com `INSTALL_FAILED_VERIFICATION_FAILURE`, rode `adb uninstall dev.caju.host` e instale de novo.

## Estrutura
- `Package.swift`: pacote Swift independente (biblioteca dinâmica `CajuAndroidHost`), depende do pacote raiz por caminho.
- `Sources/CajuAndroidHost`: `ANativeActivity_onCreate` e o jogo do triângulo (`CajuAndroidGameDelegate`).
- `scripts/build-native.sh`: compila os objetos, liga com o clang/lld do NDK e empacota o runtime do Swift.
- `scripts/compile-shaders.sh`, `shaders/`: GLSL → SPIR-V → Swift gerado em `CajuRHIVulkan`.
- `app/`, `*.gradle.kts`, `gradlew`: projeto Gradle (AGP 8.13.2, `minSdk 29`, `arm64-v8a`).

## Estado
Triângulo rodando no S22+ (evidências em `docs/evidencias/tb-android/`), com ciclos Home/volta (superfície destruída e recriada) e toque chegando à Game Thread. Pendente: rotação (manifesto fixo em retrato), *validation layers*, o backend `CajuRHI`, medir quadros/consumo e tamanho do APK com o runtime otimizado, CI do APK.

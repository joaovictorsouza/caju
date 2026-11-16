# Host Android

APK mínimo (NativeActivity, sem código Java) que carrega `libCajuAndroidHost.so`, escrita em Swift, e desenha um triângulo girando pelo `CajuRHI` (backend Vulkan) na Game Thread. Também traz o executável da suíte de conformidade do RHI. Decisões: [ADR 0019](../../docs/adr/0019-host-android-build-e-link.md), [ADR 0008](../../docs/adr/0008-android-game-thread.md), [ADR 0024](../../docs/adr/0024-vulkan-vma-e-sincronizacao.md).

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

### Toolchain open-source (obrigatório para o host e a conformidade)
O toolchain do Xcode não traz `swift-autolink-extract`, e `swift build --swift-sdk aarch64-unknown-linux-android29 --product ...` falha no passo de link. Instale o toolchain de swift.org da mesma versão do SDK (6.4.2; sem sudo, o Xcode fica intacto):
```sh
curl -fLO https://download.swift.org/swift-6.4.2-release/xcode/swift-6.4.2-RELEASE/swift-6.4.2-RELEASE-osx.pkg
pkgutil --check-signature swift-6.4.2-RELEASE-osx.pkg   # Developer ID Installer: Swift Open Source
installer -pkg swift-6.4.2-RELEASE-osx.pkg -target CurrentUserHomeDirectory   # instala em ~/Library/Developer/Toolchains
export TOOLCHAINS=org.swift.642202610261a   # CFBundleIdentifier do .xctoolchain instalado
export ANDROID_NDK_HOME=~/Library/Android/sdk/ndk/30.0.15729638
swift build -c release --swift-sdk aarch64-unknown-linux-android29 --product caju-bench   # passa (verificado em 2026-11-15)
```
Os scripts deste diretório usam esse toolchain (`TOOLCHAINS`, padrão `org.swift.642202610261a`): `swift build --product` liga direto, inclusive o alvo C++ do VMA. O link manual antigo saiu (ADR 0024).

## Gerar, instalar e rodar
```sh
cd Hosts/Android
./gradlew :app:assembleDebug        # chama scripts/build-native.sh (Swift → .so + runtime em jniLibs)
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n dev.caju.host/android.app.NativeActivity
adb logcat -s Caju CajuVulkan        # ciclo de vida, recriação do swapchain e erros de validação
adb exec-out screencap -p > print.png
```

### Camada de validação (depuração)
```sh
sh scripts/fetch-validation-layer.sh           # Khronos 1.4.363.1, só arm64, hash conferido (~27 MB)
CAJU_VALIDATION=1 ./gradlew :app:assembleDebug  # empacota libVkLayer_khronos_validation.so no APK
```
O host liga a camada no build de depuração. Erros do Khronos saem no logcat com a tag `CajuVulkan`; dicas do driver Adreno (ex.: `VKDBGUTILWARN003`) saem como `CajuVulkanDriver` e não contam como erro.

### Conformidade do RHI e ciclos de vida
```sh
sh scripts/run-conformance.sh          # suíte CajuRHIConformance no aparelho, sem janela (adb shell)
sh scripts/lifecycle-cycles.sh 50 l.log  # 50 × (rotação + Home/volta) com o APK instalado: RSS e validação
```
Se `adb install -r` falhar com `INSTALL_FAILED_VERIFICATION_FAILURE`, rode `adb uninstall dev.caju.host` e instale de novo.

## Estrutura
- `Package.swift`: pacote Swift independente (biblioteca dinâmica `CajuAndroidHost`), depende do pacote raiz por caminho.
- `Sources/CajuAndroidHost`: `ANativeActivity_onCreate` e o jogo do triângulo (`CajuAndroidGameDelegate`) sobre o `CajuRHI`.
- `Sources/CajuConformanceRunner`: executável `caju-conformance` (suíte do RHI no Vulkan).
- `scripts/build-native.sh`: `swift build --product CajuAndroidHost` e empacota o runtime do Swift (e a camada de validação com `CAJU_VALIDATION=1`).
- `scripts/compile-shaders.sh`, `shaders/`: GLSL → SPIR-V → Swift gerado no host e no executável de conformidade.
- `scripts/run-conformance.sh`, `scripts/lifecycle-cycles.sh`, `scripts/fetch-validation-layer.sh`.
- `app/`, `*.gradle.kts`, `gradlew`: projeto Gradle (AGP 8.13.2, `minSdk 29`, `arm64-v8a`).

## Estado
Triângulo pelo `CajuRHI` no S22+ com rotação liberada (`fullUser`: segue o sensor e respeita a trava do usuário), Home/volta e camada de validação sem erros; conformidade 6/6 igual ao Metal. Evidências em `docs/evidencias/v1-vulkan/`. Pendente: CI do APK (fatia F) e medir consumo/quadros com o runtime otimizado.

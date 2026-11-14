# ADR 0019: Host Android: NativeActivity em Swift, `CVulkan` e link com o NDK

**Status:** Aceito (TB-Android; implementa os ADR 0007 e 0008, não os substitui).

## Contexto
O TB-Android (ADR 0006, limite de 3 dias pelo ADR 0011) precisava de um APK com Swift e Vulkan no Galaxy S22+ (Snapdragon 8 Gen 1, Adreno 730). Três arestas apareceram: como falar com a `Activity` sem Java, como importar os cabeçalhos Vulkan (o `Package.swift` é trancado e só muda em commit dedicado), e como ligar a biblioteca Swift no Mac.

## Decisão
- **NativeActivity, sem Java/Kotlin, sem CMake e sem JNI.** O manifesto declara `android.app.NativeActivity` com `android:hasCode="false"` e `android.app.lib_name = CajuAndroidHost`. O ponto de entrada `ANativeActivity_onCreate` é uma função `@_cdecl` em Swift (pacote `Hosts/Android`, biblioteca dinâmica `CajuAndroidHost`). Os *callbacks* da Activity só enfileiram eventos numa `CajuMailbox` (anel pré-alocado); o jogo roda numa `CajuGameThread` própria (ADR 0008). `onNativeWindowDestroyed` e `onInputQueueDestroyed` esperam um `CajuHandshake` (limite de 2 s) para que a janela só seja liberada depois de a Game Thread soltá-la.
- **`CVulkan`:** target `systemLibrary` em `Sources/CVulkan` (modulemap com `link "vulkan"`, `"android"`, `"log"`) usado por `CajuRHIVulkan` e `CajuPlatform` só no Android (`.when(platforms: [.android])`). O `Package.swift` raiz mudou num **commit dedicado**, que também adicionou os alvos de teste `CajuPlatformTests` e `CajuRHIVulkanTests`.
- **Gradle** (AGP 8.13.2, Gradle 8.14.3, `minSdk 29`, `arm64-v8a`) só empacota. A tarefa `buildSwiftHost` chama `Hosts/Android/scripts/build-native.sh`.
- **Link manual.** O toolchain do Xcode não traz `swift-autolink-extract`, que o `swift build` exige ao ligar para Android (erro `unableToFind(tool: "swift-autolink-extract")`; verificado com o Swift 6.4.2 e o Swift SDK for Android 6.4.2). O script compila só os objetos (`swift build --target CajuAndroidHost`) e liga com o clang/lld do NDK r30 mais `swiftrt.o` e as bibliotecas do runtime do Swift SDK, exportando `ANativeActivity_onCreate`. As dependências (`DT_NEEDED`) transitivas do runtime (`libswiftCore.so`, `libswift_Concurrency.so`, `libdispatch.so`, `libswift_RegexParser.so`...) e o `libc++_shared.so` são resolvidos pelo script e empacotados em `jniLibs/arm64-v8a`.
- **Shaders** em GLSL (`Hosts/Android/shaders`) compilados para SPIR-V por `glslc` (`scripts/compile-shaders.sh`) e embutidos como `[UInt32]` em Swift gerado. Slang entra com o contrato do RHI.

## Alternativas
- CMake + JNI + `GameActivity`: mais peças e Java/Kotlin; adiado até haver necessidade (IME, insets).
- Toolchain open source do swift.org (traz `swift-autolink-extract`): é a saída definitiva, mas é uma instalação grande; fica como troca possível do link manual.
- Carregar `libvulkan.so` por `dlopen` sem cabeçalhos: evita o `Package.swift`, mas exige reescrever à mão cada struct Vulkan.
- Alterar o `swift-autolink-extract` do Xcode: rejeitado (modifica uma instalação do sistema).

## Consequências
- O APK de depuração pesa cerca de 26 MB `(?)`, quase todo o runtime do Swift (`libswiftCore.so` 11,7 MB, `libc++_shared.so` 9,5 MB). Medir com `-static-stdlib`/otimização no gate.
- `build-native.sh` precisa do NDK r30 (o `ANDROID_NDK_HOME` apontando para outra versão é ignorado pelo Gradle) e do Swift SDK for Android instalado.
- O CI `android` (`skiptools/swift-android-action`) continua só compilando os módulos; o APK ainda não está no CI.

## Quando reabrir
Se o toolchain do swift.org passar a ser pré-requisito (volta o `swift build` completo para Android), se o `GameActivity` for necessário (IME, insets), ou se o runtime empacotado ultrapassar o teto de tamanho do gate.

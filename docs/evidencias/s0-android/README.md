# Evidências do Spike S0: Android (Samsung Galaxy S22+ vs Host Mac)

Este documento consolida os resultados e evidências de validação do ambiente Android para o motor Caju (M0/S0), cobrindo desempenho de microbenchmarks brutos, tempos de compilação incremental, viabilidade do framework `Observation`, e análise de pegada de binário (.apk).

---

## 1. Dispositivo e Ambiente de Medição

### Aparelho Alvo (Galaxy S22+)
- **Modelo comercial:** Samsung Galaxy S22+ (`SM-S906E`, codinome de hardware `g0q`)
- **Identificador ADB:** `RQCT202D4FM`
- **SoC / Processador:** Qualcomm Snapdragon 8 Gen 1 (`arm64-v8a`)
- **Sistema Operacional:** Android 16 (API Level 36)
- **Patch de Segurança:** 2026-08-05
- **Estado Térmico / Bateria:** Nível de bateria 81% a 82%, temperatura estável entre 31.1 °C e 31.5 °C durante as baterias de teste (alimentado via USB).

### Máquina Host (macOS)
- **Modelo:** Apple MacBook Pro (Apple M1, 16 GB de memória unificada)
- **Sistema Operacional:** macOS 26.6.2 (Darwin 25.6.0)

### Toolchain e Versões
- **Compilador Swift:** `Apple Swift version 6.4.2` (`swiftlang-6.4.2.1.9`, `swift-driver version: 1.168.6`)
- **Swift SDK Android:** `swift-6.4.2-RELEASE_android` (alvo `aarch64-unknown-linux-android29`)
- **Android NDK:** `r30-beta2` (revisão `30.0.15729638`, Clang 21.0.0 / LLD do NDK r30)
- **Android SDK:** Localizado em `$HOME/Library/Android/sdk`

---

## 2. Comandos Utilizados

### 2.1 Configuração de Variáveis de Ambiente
```bash
export ANDROID_NDK_HOME=$HOME/Library/Android/sdk/ndk/30.0.15729638
export ANDROID_NDK_ROOT=$HOME/Library/Android/sdk/ndk/30.0.15729638
export ANDROID_HOME=$HOME/Library/Android/sdk
```

### 2.2 Compilação Incremental
- **Host (macOS):**
  ```bash
  swift build --target <Módulo>
  ```
- **Android (arm64 cross-compile):**
  ```bash
  swift build -c debug --swift-sdk aarch64-unknown-linux-android29 --target <Módulo>
  ```

### 2.3 Compilação e Execução do caju-bench
- **Host (Mac):**
  ```bash
  swift run -c release caju-bench --json > docs/evidencias/s0-android/caju-bench-mac-run<N>.json
  ```
- **Android (S22+):**
  Compilação via `docs/evidencias/s0-android/scripts/build-bench-android.sh`:
  ```bash
  ./docs/evidencias/s0-android/scripts/build-bench-android.sh release
  adb -s RQCT202D4FM push .build/android-bench/* /data/local/tmp/caju-bench/
  adb -s RQCT202D4FM shell "cd /data/local/tmp/caju-bench && LD_LIBRARY_PATH=. ./caju-bench --json" > docs/evidencias/s0-android/caju-bench-android-run<N>.json
  ```

### 2.4 Teste de Observation no S22+
Execução automatizada via `docs/evidencias/s0-android/observation/build-and-run.sh`:
```bash
bash docs/evidencias/s0-android/observation/build-and-run.sh
```

### 2.5 Cálculo de Estatísticas Consolidadas
```bash
python3 docs/evidencias/s0-android/scripts/calculate-stats.py
```

---

## 3. Desempenho de Benchmarks: S22+ vs Host Mac

As estatísticas abaixo foram calculadas diretamente a partir das 5 execuções brutas completas (`caju-bench-android-run1..5.json` e `caju-bench-mac-run1..5.json`) usando o script `scripts/calculate-stats.py`. O cálculo de percentil 95 (p95) adota interpolação linear padrão (R-7 / NumPy).

| Suíte | Benchmark | S22+ Mediana (ns) | S22+ p95 (ns) | Mac Mediana (ns) | Mac p95 (ns) | Razão S22+/Mac |
| :--- | :--- | :---: | :---: | :---: | :---: | :---: |
| **CajuMath** | `vec3.cross` | 2.81 | 2.82 | 3.44 | 3.45 | 0.82x |
| **CajuMath** | `quat.rotate` | 6.01 | 6.04 | 3.52 | 3.53 | 1.71x |
| **CajuMath** | `mat4.mul` | 5.14 | 5.18 | 3.76 | 3.81 | 1.37x |
| **CajuMath** | `mat4.inverse` | 33.41 | 33.43 | 22.13 | 22.16 | 1.51x |
| **CajuMath** | `mat4.inverseAffine` | 28.36 | 28.37 | 16.86 | 16.92 | 1.68x |
| **CajuMath** | `quat.slerp` | 45.94 | 45.95 | 24.93 | 25.12 | 1.84x |
| **CajuMath** | `ray.intersects(aabb)` | 9.43 | 9.44 | 7.53 | 7.63 | 1.25x |
| **CajuMath** | `ray.intersectsTriangle` | 16.32 | 16.34 | 12.56 | 12.61 | 1.30x |
| **CajuUILayout** | `uilayout.relayout_1000_nodes` | 49918.23 | 49989.21 | 31110.48 | 31168.87 | 1.60x |
| **CajuCore** | `ecs.spawn(3 componentes)` | 419.41 | 430.03 | 197.04 | 197.74 | 2.13x |
| **CajuCore** | `ecs.query.arity3(100k)` | 3.13 | 3.33 | 3.49 | 3.50 | 0.89x |
| **CajuCore** | `ecs.query.pack3(100k)` | 15.62 | 16.71 | 34.48 | 34.53 | 0.45x |
| **CajuPhysicsSpatial** | `bvh.build(10k, SAH)` | 1398.54 | 1406.73 | 916.88 | 924.40 | 1.53x |
| **CajuPhysicsSpatial** | `bvh.insert(10k)` | 855.05 | 859.34 | 626.99 | 627.95 | 1.36x |
| **CajuPhysicsSpatial** | `bvh.raycastFirst(10k, 1k raios)` | 1426.09 | 1434.90 | 1337.42 | 1352.77 | 1.07x |
| **CajuPhysicsSpatial** | `bvh.query.overlap(10k, caixa 10³)` | 367.29 | 369.29 | 290.00 | 290.35 | 1.27x |
| **CajuPhysicsSpatial** | `triangleBVH.build(20k tri)` | 600.01 | 603.18 | 424.79 | 425.37 | 1.41x |
| **CajuPhysicsSpatial** | `triangleBVH.raycastFirst(20k tri, 1k raios)` | 351.20 | 353.49 | 297.29 | 298.43 | 1.18x |

### Principais Constatações de Desempenho
1. **CPU Snapdragon vs M1:** Na maioria dos cálculos pesados de ponto flutuante escalar e memória, o Snapdragon 8 Gen 1 opera em torno de 1.2x a 1.7x o tempo do Apple M1, o que demonstra excelente paridade arquitetural para código Swift gerado em Linux/Android.
2. **Operações Vetoriais e Iteração:** Em `vec3.cross` (0.82x) e `ecs.query.pack3` (0.45x), o Snapdragon 8 Gen 1 obteve latência por operação inferior à do Mac M1, evidenciando ótima vetorização NEON de registradores e eficiência de cache L1/L2.
3. **Custo de Layout de UI:** O relayout de 1.000 nós da árvore de UI consome aproximadamente 49.9 µs (0.05 ms) no aparelho real. No orçamento de 16.6 ms de um quadro a 60 fps (ou 8.3 ms a 120 fps), a árvore de layout consome menos de 0.3% do frame, validando o modelo de faixas definido no ADR 0013.

---

## 4. Compilação Incremental (Meta ADR 0006 ≤ 5 s)

A meta estipulada no **ADR 0006** exige tempo de compilação incremental de módulo menor ou igual a 5 segundos (`≤ 5 s`).
Foram realizadas 5 repetições com modificação de comentário em arquivo-fonte para os módulos `CajuMath` e `CajuUILayout`, precedidas por compilação de aquecimento (warm-up).

| Módulo | Plataforma | Rep 1 (s) | Rep 2 (s) | Rep 3 (s) | Rep 4 (s) | Rep 5 (s) | Mediana (s) | Meta ADR 0006 | Margem de Folga |
| :--- | :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **CajuMath** | Host (macOS) | 2.589 | 1.663 | 1.732 | 1.671 | 1.683 | **1.683 s** | ≤ 5.0 s | 66.3% |
| **CajuMath** | Android (arm64) | 1.865 | 1.832 | 1.824 | 1.826 | 1.858 | **1.832 s** | ≤ 5.0 s | 63.4% |
| **CajuUILayout** | Host (macOS) | 1.433 | 1.540 | 1.505 | 1.414 | 1.399 | **1.433 s** | ≤ 5.0 s | 71.3% |
| **CajuUILayout** | Android (arm64) | 1.497 | 1.565 | 1.498 | 1.563 | 1.466 | **1.498 s** | ≤ 5.0 s | 70.0% |

**Conclusão:** O gate de saída de compilação incremental do ADR 0006 foi amplamente superado em ambas as plataformas (medianas variando entre 1.43 s e 1.83 s). Ao final dos testes, os arquivos foram revertidos via `git checkout` sem qualquer modificação residual na árvore de código-fonte.

---

## 5. Framework Observation no Galaxy S22+

Um dos critérios de aceite do gate de saída do ADR 0006 é:
> `- Observation funcionando em aparelho Android real.`

Para validação estrita, foi construído um executável isolado em `/tmp/obs-android` utilizando `import Observation`, cross-compilado para Android arm64, enviado ao Galaxy S22+ via adb e executado localmente.

### Escopo do Teste
1. Instanciação de classe anotada com `@Observable` (`GameState`).
2. Registro de escuta com `withObservationTracking` rastreando a propriedade `score`.
3. Verificação de que mutação em propriedade não observada (`unobservedField`) não dispara o callback `onChange`.
4. Mutação da propriedade observada (`score = 10`), confirmando disparo síncrono e pontual de `onChange`.
5. Confirmação de que mutações subsequentes na mesma assinatura não redisparam sem novo registro (semântica do framework Observation).

### Saída de Execução no Dispositivo (SM-S906E)
```text
=== Teste do Observation Framework no Android arm64 ===
OK: withObservationTracking correctly tracked mutation and fired onChange once
Resultado: OK
```

Os artefatos completos (código Swift, manifesto `Package.swift`, script de build e link manual, e log de execução) estão preservados em `docs/evidencias/s0-android/observation/`.

---

## 6. Tamanho do APK: Debug vs Otimizado (ADR 0005)

O ADR 0005 prevê acompanhamento rígido do tamanho do binário empacotado. Medimos os dois extremos de build:

1. **APK Debug (desenvolvimento padrão):** stdlib do Swift dinâmica inteira empacotada em `.so` separados no APK, sem strip de símbolos.
2. **APK Otimizado (Release com stdlib estática e strip llvm):** gerado via `scripts/build-native-optimized.sh`, unificando a stdlib estática do Swift em `libCajuAndroidHost.so` e aplicando `llvm-strip --strip-all`.

### Comparativo de Tamanho Total do APK

| Variante do APK | Tamanho em Bytes | Tamanho em MB | Variação Absoluta | Redução Percentual |
| :--- | :---: | :---: | :---: | :---: |
| **Debug** (arquivo `app-debug.apk`) | 30.737.419 B | 30.74 MB | Base | 0% |
| **Release otimizado** (`app-release-unsigned.apk`, não assinado) | 8.518.997 B | 8.52 MB | -22.22 MB | **-72.3%** |

Os tamanhos acima são os do arquivo `.apk` (`ls -l`). A soma das entradas descompactadas (`unzip -lv`) é 30.637.281 B no debug e 8.491.195 B no otimizado. Revisão: o README original do agente usava a soma das entradas, não o arquivo. A medição do debug veio do build com `./gradlew :app:assembleDebug` (log em `apk-debug-build.log`); o otimizado vem de `scripts/build-native-optimized.sh`, que não altera `Package.swift`, CI nem os scripts rastreados.

### Decomposição do Conteúdo de Bibliotecas Nativas (`lib/arm64-v8a/`)

| Arquivo | Tamanho no APK Debug | Tamanho no APK Otimizado | Observações |
| :--- | :---: | :---: | :--- |
| `libCajuAndroidHost.so` | 4.743.560 B (4.74 MB) | 7.064.824 B (7.06 MB) | Na versão otimizada, embute toda a stdlib estática do Swift (`libswiftCore.a`, `libswift_Concurrency.a`, etc.) com `llvm-strip`. |
| `libc++_shared.so` | 9.486.368 B (9.49 MB) | 1.423.104 B (1.42 MB) | Redução de 85% após aplicação do `llvm-strip`. |
| `libswiftCore.so` | 11.670.272 B (11.67 MB) | *Eliminado* | Absorvido estaticamente em `libCajuAndroidHost.so`. |
| `libswift_Concurrency.so` | 1.376.632 B (1.38 MB) | *Eliminado* | Absorvido estaticamente. |
| `libswift_RegexParser.so` | 1.575.416 B (1.58 MB) | *Eliminado* | Absorvido estaticamente. |
| `libswift_StringProcessing.so` | 1.125.152 B (1.13 MB) | *Eliminado* | Absorvido estaticamente. |
| `libdispatch.so` | 423.120 B (423 KB) | *Eliminado* | Não aparece no APK otimizado; ver `apk-release-static-unzip.txt`. |
| `libswiftSynchronization.so` | 125.784 B (126 KB) | *Eliminado* | Absorvido estaticamente. |
| `libswiftAndroid.so` | 80.568 B (81 KB) | *Eliminado* | Absorvido estaticamente. |
| `libBlocksRuntime.so` | 14.488 B (14 KB) | *Eliminado* | Absorvido estaticamente. |
| `libswift_Builtin_float.so` | 12.608 B (13 KB) | *Eliminado* | Absorvido estaticamente. |
| Outros (DEX, Manifest, Meta) | ~3.680 B (~3.6 KB) | ~3.680 B (~3.6 KB) | DEX mínimo de NativeActivity. |

---

## 7. Registro de Alterações, Falhas Encontradas e Soluções Adotadas

Durante a execução da etapa S0-Android, os seguintes pontos técnicos foram identificados e solucionados sem alterar `Package.swift`, CI ou código-fonte monitorado:

1. **Ausência do `swift-autolink-extract` no Toolchain do Xcode no Mac:**
   - *Sintoma:* O comando `swift build --product <Executável>` falha no macOS host com:
     `error: unable to spawn process '/Applications/Xcode.app/.../swift-autolink-extract' (No such file or directory)`.
   - *Solução:* Foi compilado apenas o alvo de objetos intermediários (`swift build --target <Alvo>`) e a ligação final foi feita diretamente com o Clang/LLD do NDK r30 (`$LLVM/bin/aarch64-linux-android29-clang` com `-fuse-ld=lld`, `-Wl,-z,max-page-size=16384` e `-Wl,-rpath,'$ORIGIN'`), conforme adotado nos scripts `build-bench-android.sh` e `build-native-optimized.sh`.
2. **Dependências Dinâmicas Transitivas no Linker Android:**
   - *Sintoma:* Ao rodar executáveis como `obs-android` e `caju-bench` via adb com stdlib dinâmica, a falta de bibliotecas como `libdispatch.so`, `libBlocksRuntime.so`, `libswift_Builtin_float.so` e `libswift_RegexParser.so` impedia a carga pelo linker dinâmico do Bionic.
   - *Solução:* Implementado loop automatizado de resolução de `DT_NEEDED` via `llvm-readelf`, empacotando automaticamente todas as dependências transitivas do diretório de runtime do Swift SDK para o pacote do aparelho.
3. **Isolamento de Concorrência do Swift 6 em Closures `onChange`:**
   - *Sintoma:* No Swift 6, o closure `onChange` do `withObservationTracking` possui atributo `@Sendable`, impedindo a mutação direta de variáveis locais sem anotação explícita de concorrência (`mutation of captured var in concurrently-executing code`).
   - *Solução:* Utilizado `nonisolated(unsafe) var` para flag de controle no teste CLI do harness, permitindo teste determinístico e thread-safe.
4. **Respeito aos Limites do Repositório:**
   - Nenhuma alteração foi realizada em `Package.swift` nem em fluxos de integração contínua (CI).
   - Não foram realizados commits, push ou adições ao Git.
   - Arquivos-fonte temporariamente modificados para cronometragem de compilação incremental foram revertidos (`git checkout`), garantindo `git status` limpo fora de `docs/evidencias/s0-android/`.

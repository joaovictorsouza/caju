# ADR 0010: Fundação do M0 (pacote, CI, host, prefixo)

**Status:** Aceito (implementado no M0).

## Contexto
O M0 cria o esqueleto que todas as trilhas da Onda 0.5 vão usar em paralelo. O que for decidido aqui trava o `Package.swift` e o CI (alterações só por PR dedicado).

## Decisão
- **Prefixo `Caju*`** em módulos e tipos públicos (D5 decidido pelo dono). Identificadores em inglês.
- **Um target por módulo do mapa de camadas (§5 do plano)**, mais `CajuRHIMetal`/`CajuRHIVulkan` (backends separados) e `CajuScripting` (placeholder; ADR 0004). Dependências só para baixo, declaradas no `Package.swift`. Cada módulo tem `README.md` em `Sources/<Módulo>/` (excluído do alvo) e, enquanto não tem trilha, só um marcador `<Módulo>Module`.
- **Toolchain:** `swift-tools-version: 6.2`, modo de linguagem Swift 6 (concorrência estrita) e `.treatAllWarnings(as: .error)` em todos os targets. Plataformas: iOS 17, macOS 14 (par do iOS 17); Android API 29 via Swift SDK for Android (ADR 0007).
- **CI (GitHub Actions):** `lint` (`swift format lint --strict` e `scripts/check-forbidden.sh`: `try!`, `as!`, `fatalError(`, `precondition(` fora de testes), `linux` (build, testes, TSan, benchmarks em JSON), `macos` (build, testes, build iOS), `android` e `apple-host` **experimentais** (`continue-on-error`) até a primeira execução verde / fixação do SDK no TB-Android.
- **Benchmark:** executável `caju-bench` (alvo `CajuBenchmarks`) emite JSON; o gate de regressão > 10 % só liga quando houver linha de base medida **no aparelho de referência** (números do CI são de runner genérico).
- **Fuzz/testes determinísticos:** `CajuTesting` fornece `CajuPCG32` (PRNG semeável) e `CajuFuzz.run`.
- **Host Apple:** `Hosts/Apple` (SwiftUI mínimo, projeto gerado por XcodeGen; `.xcodeproj` não versionado).
- **Math:** `CajuMath` usa `Float`/SIMD, coluna-maior, sem Foundation (libc para `sinf`/`cosf`).

## Alternativas
Projeto Xcode versionado (conflitos de merge em trilhas paralelas); SwiftLint (mais uma dependência: `swift format` já vem no toolchain e o lint de construções proibidas é um script de 5 linhas).

## Consequências
`Package.swift` e CI ficam trancados. Os jobs experimentais precisam virar obrigatórios por PR dedicado.

## Quando reabrir
Se o Swift SDK for Android exigir outro fluxo de build; se o lint por script ficar insuficiente (adotar SwiftLint).

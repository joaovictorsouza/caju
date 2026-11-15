# ADR 0030: Macro `@Component(id:)` com `swift-syntax`

**Status:** Aceito. Complementa o [ADR 0014](0014-ecs-query-e-component.md) (que adiou a macro) e segue a política do [ADR 0005](0005-dependencias-e-foundation.md).

## Contexto
O ADR 0014 definiu `CajuComponent` por protocolo com `static var componentID` manual e previu que uma macro poderia gerar só o ID, assim que houvesse `swift-syntax` (mudança no `Package.swift`, em PR dedicado).

## Decisão
- Novo alvo `.macro` **`CajuMacrosPlugin`** (`Sources/CajuMacrosPlugin`) e dependência **`swift-syntax` fixada em `602.0.0`** (par do Swift 6.2; licença Apache 2.0). Só o `SwiftSyntaxMacros`/`SwiftCompilerPlugin` entram; o plugin roda no host, durante a compilação, e **não entra no binário do jogo** (iOS/Android/macOS).
- `CajuCore` declara `@attached(extension) macro Component(id: UInt8)`. Expansão: `extension T: CajuComponent { static let componentID = CajuComponentID(id) }`, com `public` quando o tipo é `public`/`open`.
- Diagnósticos de compilação: só `struct`/`enum` (colunas exigem `BitwiseCopyable`) e `id` como **literal inteiro em 0..<64**. Duplicidade de ID continua sendo detectada em tempo de execução pelo mundo (`componentIDConflict`); a macro não vê outros tipos.
- O contrato não muda: `CajuComponent` e o `componentID` manual seguem válidos; a macro é açúcar opcional. Nenhum código existente foi migrado.
- Testes: `assertMacroExpansion` em `CajuMacrosPluginTests` (XCTest, pois o suporte de teste do `swift-syntax` reporta via XCTest) e teste de integração em `CajuCoreTests`.

## Alternativas
- Manter só o protocolo: sem custo de compilação, mas IDs manuais e repetitivos.
- Gerar o ID por hash/nome em tempo de execução: perde o `componentID` estático e a faixa por camada (0–15 núcleo, 16–47 módulos, 48–63 jogo).

## Consequências
- Job `android` (experimental): o teste de integração que **usa** a macro fica fora do Android (`#if !os(Android)`), pois o build cruzado com índice falha ao abrir o índice do código expandido; reavaliar quando o SDK Android fixar (ADR 0008).
- Build limpo mais lento por compilar `swift-syntax` (tempo não medido `(?)`; medir no CI, conforme o plano §risco de compilação). Builds incrementais não recompilam a dependência.
- A primeira resolução do pacote baixa `swift-syntax` (rede no CI/ambiente de build).
- `@Component(id:)` futuramente pode crescer (`@Message`, `@Resource`, `#shader`, previstos no plano) no mesmo plugin.

## Quando reabrir
Se o tempo de build limpo no CI for inaceitável (usar *prebuilt* de `swift-syntax` quando o SwiftPM suportar) ou se o ID por macro precisar de verificação de unicidade entre módulos.

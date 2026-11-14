# ADR 0014: ECS da TB-1: `Query` por overloads de aridade 1..8 e `Component` por protocolo

**Status:** Aceito. Complementa o [ADR 0003](0003-ecs-e-agendador.md) (que previa este plano B).

## Contexto
O ADR 0003 exigia um PoC de `Query` com *parameter packs* e inspeção de SIL (zero `swift_allocObject`, sem *witness tables*) antes de congelar a API, com fallback de overloads de aridade 1..8. O PoC foi feito na TB-1 (Swift 6.4.2, `-O`, `swiftc -emit-sil` sobre uma função que chama `forEach`).

## Resultados do PoC
| Variante | `swift_allocObject`/`alloc_ref`/`alloc_box` | `witness_method` no laço | ns/entidade (100 mil entidades, 3 componentes, macOS, `-O`) |
|---|---|---|---|
| Packs (`forEachPack`) | 0 (fechamento `on_stack`) | **sim**: 1 por termo e por linha (`cursor`/`item`) | ≈ 38,7 |
| Overloads aridade 1..8 (`forEach`) | 0 | **0** | ≈ 3,7 |

O compilador especializa o `forEach` por pack, mas dentro do laço os termos continuam despachados por *witness table* (`pack_element`). Isso reprova o critério do ADR 0003 e custa ~10×.

## Decisão
1. `forEach` de aridade 1..8 **gerado** (`docs/tools/gen-query-overloads.py` → `Sources/CajuCore/CajuQueryArity.swift`) é a API de consulta do caminho quente, tanto em `CajuWorld` quanto na versão validada de `CajuSystemContext`.
2. A versão com packs permanece como `forEachPack` (aridade > 8, referência do PoC). `spawn` também usa packs (só registra e escreve bytes por componente; medido ≈ 199 ns/entidade com 3 componentes, ≈ 5 M/s).
3. **`Component` por protocolo** com `static var componentID` (0..<64) e `BitwiseCopyable`, no lugar da macro `@Component`: a macro exigiria `swift-syntax` (PR dedicado ao `Package.swift`, ADR 0005). A macro poderá apenas gerar o `componentID`.
4. `BitwiseCopyable` é obrigatório porque as colunas movem bytes sem ARC/`deinit` (sem alocação e sem *witness* no `despawn`/mover). `CajuMath` ainda não declara `BitwiseCopyable` em `CajuVec3`/`CajuQuat`; `CajuTransform` guarda `SIMD` e expõe os tipos do `CajuMath` por acessores. Sugestão para o dono do `CajuMath`: conformar os tipos públicos a `BitwiseCopyable`.
5. Agendador: `CajuSystemContext` valida cada consulta contra `reads`/`writes` declarados (`CajuAccessError`); `build()` ordena por estágio com arestas de conflito (W×W, W×R) e `after:` explícito, em níveis (`batches`) que serão a base de paralelização futura. Mudança estrutural só por `CajuCommandBuffer` nos pontos de sincronização entre estágios (e `CajuWorld` recusa spawn/despawn durante consulta).

## Alternativas
- Só packs: ~10× mais lento no laço (acima).
- Macro `@Component` agora: depende de `swift-syntax`; adiado.
- Colunas com `Array<T>` por tipo (type-erased por classe): ARC/alocação e dispatch dinâmico no caminho quente.

## Consequências
- Máx. 64 tipos de componente e 64 *tags* por mundo (IDs por faixa: 0–15 núcleo, 16–47 módulos, 48–63 jogo).
- Aliasing: pedir o mesmo componente duas vezes numa consulta (p. ex. `CajuWrite<A>` e `CajuRead<A>`) é responsabilidade de quem chama.
- A inspeção de SIL é manual (comando abaixo); automatizar no CI cabe a quem mantém o CI.

```bash
swift build -c release --product caju-bench
swiftc -O -emit-sil -I .build/out/Products/Release -module-name T prova.swift | grep -E "witness_method|alloc_ref|allocObject"
```

## Quando reabrir
Quando o compilador devolver *witness* zero nos packs (reavaliar `forEach` por packs), ou quando houver `swift-syntax` para a macro.

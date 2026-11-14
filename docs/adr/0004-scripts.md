# ADR 0004: Scripts em runtime: embarcados e adiados

**Status:** Aceito (decisão do dono: embarcados de início; implementação no futuro, não agora).

## Decisão
- **Nenhum runtime de scripts agora.** Scripting entra depois do vertical slice (Onda 5).
- Quando entrar: **Luau embarcado** no bundle. WASM sai do roadmap por ora (binários Swift→wasm grandes, interpretador 15–30× mais lento (?), custo de cruzar memória linear).
- **Scripts baixados** (remotos) ficam fora até análise de política de loja (Apple 2.5.2) e assinatura.
- **Custo agora (Fase 1):** apenas `componentID` estável (hash determinístico) e **tabela de reflexão estática** gerada por `@Component`. A API dinâmica do `World` fica adiada.
- `dlopen` de Swift só serve para *hot reload* de desenvolvimento no macOS com funções `@_cdecl`; não substitui scripting.

## Quando reabrir
Ao iniciar a Onda 5, ou se um jogo precisar de lógica configurável antes disso.

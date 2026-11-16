# CajuToolsCore

Lógica pura da CLI `caju-tools` (parser de argumentos, `texture`, `validate-gltf`, `manifest`), separada do executável `CajuTools` (`main.swift`) para ser testável por `CajuToolsTests` (Swift Testing, `@testable import`). Sem alocação no caminho quente: é ferramenta de build, não roda no jogo. Detalhes de uso e limites (ASTC, formatos aceitos) em [`Sources/CajuTools/README.md`](../CajuTools/README.md).

Dependências: apenas Foundation (borda, ADR 0005). Não depende de nenhum módulo do engine.

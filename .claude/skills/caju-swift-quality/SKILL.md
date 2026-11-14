---
name: caju-swift-quality
description: Use ao escrever ou revisar código Swift do Caju: aplica o padrão do projeto (valores, concorrência estrita, erros tipados, sem alocação no caminho quente, API mínima).
---

# Qualidade de código Swift no Caju

Leia `docs/standards/codigo-swift.md` e `docs/standards/performance.md`. Resumo operacional:

1. Tipos de valor e `final`; nada de `any` ou `class` no caminho quente.
2. `throws(Error)` tipado; nenhum `!`, `try!`, `fatalError`, `precondition` onde há dado externo; valide limites antes de alocar ou indexar.
3. Concorrência estrita sem avisos; `World` só no laço principal/Game Thread; sem estado global mutável.
4. Foundation só nas bordas; nunca em ECS, render, layout, animação.
5. API pública mínima, documentada em DocC; mudança de API cruzando módulos precisa de PR de contrato.
6. Rode formatação, lint, build (`-warnings-as-errors`) e testes antes de concluir.
7. Se tocou caminho quente: *benchmark* antes e depois no PR.
8. Ao terminar, aplique a skill `caju-docs-sync`.

Revisando: confira o *definition of done* em `docs/standards/pr-e-revisao.md` e se há decisão sem ADR.

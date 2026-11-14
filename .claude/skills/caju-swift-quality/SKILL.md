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

## Overrides do Caju sobre skills de terceiros
Ao usar `swift-concurrency-pro` (revisão de concorrência), valem estes limites do projeto; onde houver conflito, o ADR/standard vence:
- O `World` **não é ator** e roda só no laço/Game Thread (ADR 0003, 0008); não sugerir actor nem `@MainActor` para ECS, render, layout ou animação. `@MainActor` só nas bordas de plataforma (UIKit/JNI).
- Sem `async/await` no laço principal; pool/agendador próprio e arenas por quadro. Swift Concurrency só para I/O, rede, decodificação e ponte para o mundo.
- `@unchecked Sendable` só em internals (agendador, arenas) com comentário `// SAFETY:` e teste TSan; fora disso, preferir `sending`/valores.
- Regras de Core Data, SwiftUI/`@Observable` de app e URLSession não se aplicam ao núcleo; a UI do Caju segue o ADR 0002.
Para testes, `swift-testing-expert` vale, com `docs/standards/testes.md` por cima (benchmarks e golden próprios).

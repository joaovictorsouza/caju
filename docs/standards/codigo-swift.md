# Padrão de código Swift

## Ferramentas (configurar no M0)
- `swift-format` (formatação) e `SwiftLint` ou regras equivalentes (lint), rodando no CI; build com `-warnings-as-errors`.
- **Swift 6.2+**, `StrictConcurrency` ligado em todos os targets; nenhum aviso de concorrência aceito.
- Documentação pública em **DocC** (`///`), com exemplo mínimo nos tipos principais.

## Regras
1. **Tipos de valor por padrão**; `class` só com justificativa (identidade, ciclo de vida). `final` por padrão.
2. **Sem `any Protocol` em caminho quente;** genéricos com `@inlinable`/`@_specialize` quando medido.
3. **Erros tipados** (`throws(Error)`) em loaders, parsers e rede; mensagens com contexto (caminho do campo, índice).
4. **Dado externo é hostil:** validar limites antes de alocar/indexar; nunca `!`, `try!`, `fatalError`, `precondition` nesses caminhos. Verificado por lint.
5. **Concorrência:** o `World` só é acessado pelo laço principal/Game Thread; trabalho paralelo recebe `Span`/buffers via jobs tipados; `Sendable`/`sending` nas fronteiras; sem estado global mutável escondido.
6. **Memória:** `~Copyable` para handles únicos e encoders; `Span`/`MutableSpan`/`InlineArray` em colunas e buffers; arenas por quadro; sem `Dictionary<String,_>` por quadro.
7. **Foundation** só nas bordas (ADR 0005); nunca no ECS, render, layout ou animação.
8. **API pública mínima:** `public` só o necessário; mudança de API pública exige PR de contrato e atualização de docs (e ADR se for decisão).
9. **Nomes:** inglês nos identificadores, seguindo as *API Design Guidelines* do Swift; português só em docs.
10. **Dependências novas:** critério do ADR 0005 (licença, versão fixa, tamanho medido) e PR dedicado ao `Package.swift`.
11. **Sem código morto, sem `TODO` sem issue.**

## Proibido sem ADR
Singletons globais mutáveis, reflexão dinâmica no núcleo, `async/await` no laço principal, `Codable` em assets pesados.

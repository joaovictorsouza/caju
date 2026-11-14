# Caju: instruções para agentes e contribuidores

Engine 3D multiplataforma inteiramente em Swift. Leia antes de qualquer trabalho:

1. `docs/planejamento-engine.md` (visão atual e ordem de execução)
2. `docs/adr/README.md` (decisões e motivos)
3. `docs/standards/` (código, testes, performance, PR, definition of done)

## Regras fixas
- **Documentação viva:** toda mudança que altere comportamento, API pública, arquitetura, decisão, métrica ou processo **atualiza a documentação no mesmo PR** (skill `caju-docs-sync`). PR sem a atualização necessária não está pronto.
- **Decisão nova ou revisão de decisão = ADR** em `docs/adr/` (numerado, nunca apagado; se mudar, crie ADR que substitui e marque o antigo como "Substituído por").
- **Um diretório = um dono por vez.** Não edite módulos fora do escopo da sua trilha. `Package.swift` e CI só em PR dedicado.
- **Sem `!`, `try!`, `fatalError`, `precondition` em caminho com dado externo.** Erros tipados (`throws(E)`).
- **Sem alocação no caminho quente** (ECS, render, layout, animação). Foundation permitido só nas bordas (ADR 0005).
- **Teste junto com o código;** parsers com *fuzz*; módulos com meta de desempenho têm *benchmark*.
- Estimativas e números não medidos ficam marcados com `(?)` até medir.

## Skills do projeto (`.claude/skills/`)
- `caju-docs-sync`: manter docs, ADRs e standards atualizados.
- `caju-swift-quality`: padrão de código, concorrência, desempenho e revisão.
- `caju-testing`: estratégia de testes, *goldens*, *fuzz*, *benchmarks*.
- `caju-new-module`: criar/alterar módulo seguindo contrato e donos.

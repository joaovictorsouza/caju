# PRs, revisão e definition of done

## PRs
- Pequenos e focados; uma trilha, um diretório. Mudança em `Package.swift`, CI ou contrato entre módulos vai em PR **separado**.
- Título no imperativo; corpo explica o quê e por quê; referencia ADR/requisito.
- `rebase` frequente em `main`; sem *force push* em branch compartilhada.

## Definition of done (todo PR)
- [ ] Compila em macOS e Linux (e iOS/Android quando o módulo é de plataforma); CI verde.
- [ ] Sem avisos de concorrência; lint e formatação ok.
- [ ] Testes novos/atualizados; *fuzz* se mexeu em parser; *benchmark* se mexeu em caminho quente.
- [ ] API pública documentada (DocC).
- [ ] **Documentação atualizada** (skill `caju-docs-sync`): plano, ADRs, standards, README do módulo, o que se aplicar. Se nada se aplica, dizer isso no PR.
- [ ] Sem `!`/`try!`/`fatalError` em caminho com dado externo.
- [ ] Números novos medidos ou marcados `(?)`.

## Revisão
Revisor confere o definition of done, o escopo do dono do diretório e se há decisão arquitetural sem ADR.

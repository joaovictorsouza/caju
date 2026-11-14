## O que muda e por quê

<!-- Uma trilha, um diretório. Referencie ADR/requisito quando houver. -->

## Definition of done
- [ ] Compila em macOS e Linux (e iOS/Android se for módulo de plataforma); CI verde
- [ ] Sem avisos de concorrência; lint e formatação ok
- [ ] Testes novos/atualizados; *fuzz* se mexeu em parser; *benchmark* se mexeu em caminho quente
- [ ] API pública documentada (DocC)
- [ ] **Documentação atualizada** (plano, ADRs, standards, README do módulo, `CLAUDE.md`), ou "nenhuma mudança necessária" com a razão:
- [ ] Sem `!`/`try!`/`fatalError` em caminho com dado externo
- [ ] Números novos medidos ou marcados `(?)`
- [ ] Mudança de `Package.swift`/CI/contrato entre módulos está em PR separado

## Documentos atualizados

<!-- Liste os arquivos de docs tocados neste PR. -->

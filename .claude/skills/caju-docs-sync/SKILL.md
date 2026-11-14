---
name: caju-docs-sync
description: Use ao concluir ou revisar qualquer mudança no projeto Caju (código, API, arquitetura, dependência, processo): garante que plano, ADRs, standards, READMEs e CLAUDE.md sejam atualizados no mesmo PR.
---

# Manter a documentação do Caju atualizada

A documentação deve refletir sempre o estado atual. Faça isto **antes de abrir ou finalizar um PR**.

## Passos
1. Liste o que mudou: decisão, API pública, escopo/marcos, padrão, métrica, dependência, plataforma.
2. Consulte a tabela em `docs/standards/documentacao.md` e atualize cada documento afetado:
   - decisão → **novo ADR** (nunca apague; se substitui, marque o antigo "Substituído por ADR-xxxx") + índice em `docs/adr/README.md`;
   - escopo, ordem, marcos, riscos → `docs/planejamento-engine.md`;
   - API de módulo → DocC e `README.md` do módulo;
   - padrões/processo → `docs/standards/*`; instruções de agentes → `CLAUDE.md` e `.claude/skills/*`.
3. Troque estimativas `(?)` por valores medidos quando você os mediu; marque novas estimativas com `(?)`.
4. Procure contradições entre documentos (plano vs ADR vs standards) e corrija-as.
5. No corpo do PR, liste os documentos atualizados, ou escreva "documentação: nenhuma mudança necessária" com a razão.

## Não faça
- Deixar a atualização para um PR futuro.
- Apagar ADRs ou reescrever histórico de decisões.
- Documentar algo que não foi implementado como se já existisse.

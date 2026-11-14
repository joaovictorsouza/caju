---
name: caju-adr
description: Use ao tomar, mudar ou revogar uma decisão de arquitetura, dependência, plataforma ou processo no Caju: escreve o ADR no formato do projeto e atualiza índice e plano.
---

# Escrever um ADR no Caju

1. Veja `docs/adr/README.md` e use o próximo número livre (`NNNN-tema-curto.md`).
2. Formato: **Status**, **Contexto**, **Decisão**, **Alternativas**, **Consequências**, **Quando reabrir**. Curto (uma página). Marque números não medidos com `(?)`.
3. **Nunca apague nem reescreva** um ADR aceito. Se a decisão muda, escreva um ADR novo que o **substitui** e marque o antigo como "Substituído por ADR-NNNN".
4. Atualize o índice em `docs/adr/README.md` e os trechos afetados do `docs/planejamento-engine.md` (tabela de decisões, marcos, riscos).
5. Decisão que pertence ao dono do projeto (objetivo, escopo, custo, política de loja) é proposta com recomendação e espera aprovação; status "Proposto" até lá.
6. Aplique `caju-docs-sync` antes de concluir.

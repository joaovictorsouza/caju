---
name: caju-track-brief
description: Use ao iniciar uma trilha de trabalho do Caju (TB-1, TB-2, P-1..P-5, Onda 1...): define escopo, dono do diretório, entradas, entregas e critérios de pronto antes de escrever código.
---

# Brief de trilha do Caju

Antes de codar, escreva (no PR ou na descrição da sessão) um brief curto:

1. **Trilha e marco:** qual linha do plano (`docs/planejamento-engine.md` §8) e qual ADR a sustenta.
2. **Diretórios que você possui** e os que **não** pode tocar (`CODEOWNERS`).
3. **Contrato:** tipos/protocolos públicos de entrada e saída; dependências permitidas (só para baixo).
4. **Entregas** e **critérios de pronto** (testes, *fuzz*, *benchmark*, metas medidas nos aparelhos de referência, `docs/standards/pr-e-revisao.md`).
5. **Riscos e kill-criteria** (principalmente TB-Android: timebox de 5 dias).
6. **Documentos que você vai atualizar** (skill `caju-docs-sync`).
7. Confirme que o M-1 está aceito e que as trilhas das quais depende já passaram do gate.

Depois siga `caju-new-module`, `caju-swift-quality` e `caju-testing`.

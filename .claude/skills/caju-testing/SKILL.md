---
name: caju-testing
description: Use ao criar ou alterar testes do Caju: escolher a camada certa (unitário, propriedade/fuzz, integração headless, golden de GPU, benchmark, TSan, aparelho) e seguir as regras de determinismo.
---

# Testes no Caju

Leia `docs/standards/testes.md`.

1. Escolha a camada: puro (Linux+macOS) sempre que possível; GPU só para conformidade visual; aparelho para ciclo de vida e soak.
2. Use Swift Testing; relógio manual (`TimeUpdateStrategy.manual`) e `Random` semeável; sem relógio de parede.
3. Parsers e loaders: acrescente casos ao *fuzz* e testes com arquivos malformados; nenhuma entrada pode causar crash ou alocação acima do limite.
4. Caminho quente: acrescente ou atualize o *benchmark*; compare com a base; regressão > 10 % bloqueia.
5. *Goldens*: um conjunto por backend; só atualize com a flag explícita e explique no PR.
6. Bug corrigido = teste de regressão. Teste instável é corrigido, não desligado.
7. Rastreie requisitos `DEVE` do módulo por ID.
8. Ao terminar, aplique `caju-docs-sync` (inclusive `docs/standards/testes.md` se o processo mudou).

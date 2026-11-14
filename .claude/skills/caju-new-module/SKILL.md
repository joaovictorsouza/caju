---
name: caju-new-module
description: Use ao começar ou alterar a trilha de um módulo do Caju: confirma dono do diretório, dependências permitidas, contrato público, README do módulo, testes e docs.
---

# Trabalhar em um módulo do Caju

1. Leia `CLAUDE.md`, `docs/planejamento-engine.md` (trilha e onda do módulo) e os ADRs relacionados.
2. Confirme o **dono do diretório** (`CODEOWNERS`) e trabalhe só em `Sources/<Módulo>` e `Tests/<Módulo>Tests`. Dependências só para baixo (mapa em §5 do plano); o módulo deve compilar e testar isolado.
3. **Não edite** `Package.swift`, CI nem contratos de outros módulos: abra PR dedicado e curto.
4. Crie/atualize `README.md` do módulo: responsabilidade, dependências, como testar, decisões relevantes.
5. Escreva testes e, se houver meta, *benchmark*; parsers com *fuzz* (skill `caju-testing`).
6. Siga `caju-swift-quality`.
7. Antes do PR: `caju-docs-sync` e checklist de `docs/standards/pr-e-revisao.md`.

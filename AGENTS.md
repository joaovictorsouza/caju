# Caju: instruções para agentes

Este arquivo espelha o `CLAUDE.md` para ferramentas que leem `AGENTS.md`. **A fonte é o [`CLAUDE.md`](CLAUDE.md); se divergirem, vale o `CLAUDE.md` e este arquivo deve ser corrigido no mesmo PR.**

Leia antes de qualquer trabalho: `docs/planejamento-engine.md`, `docs/adr/README.md`, `docs/standards/README.md`.

Regras fixas: documentação viva atualizada no mesmo PR; decisão nova = ADR (ADRs não se apagam); um diretório = um dono por vez; `Package.swift` e CI só em PR dedicado; sem `!`/`try!`/`fatalError`/`precondition` com dado externo; sem alocação no caminho quente; teste junto com o código; números não medidos marcados com `(?)`.

Skills: `.claude/skills/` (`caju-docs-sync`, `caju-swift-quality`, `caju-testing`, `caju-new-module`, `caju-adr`, `caju-track-brief`).

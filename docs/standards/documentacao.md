# Documentação viva

A documentação é parte do produto: **deve ser atualizada no mesmo PR que muda o que ela descreve.**

| Mudou... | Atualize |
|---|---|
| Decisão de arquitetura, dependência, plataforma, política | ADR novo (ou ADR que substitui) + `docs/adr/README.md` + trecho do plano |
| Ordem de execução, marcos, escopo (MVP/v1.0/opcional) | `docs/planejamento-engine.md` |
| API pública de um módulo | DocC + `README.md` do módulo |
| Padrão de código, teste, performance ou processo | `docs/standards/*` |
| Meta/medida de desempenho ou tamanho | `docs/standards/performance.md` e o plano (trocar `(?)` pelo valor medido) |
| Instruções de agentes | `CLAUDE.md` e `.claude/skills/*` |

## Regras
1. ADRs **não se apagam**: se a decisão muda, escreva ADR novo que substitui e marque o antigo.
2. Todo módulo tem `README.md`: responsabilidade, dependências, como testar, decisões relevantes.
3. Estimativas ficam com `(?)` até serem medidas.
4. Se uma doc estiver errada ou desatualizada, corrigir é parte de qualquer PR que a perceba.
5. Sessões que executam trilhas devem ler `CLAUDE.md` e os docs relevantes antes de começar e conferir, ao terminar, se algo precisa ser atualizado.

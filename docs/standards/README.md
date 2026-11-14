# Padrões do projeto

Cada documento é normativo para quem contribui (pessoas e agentes). Mudou um padrão: atualize o documento no mesmo PR e, se for decisão, abra ADR.

- [codigo-swift.md](codigo-swift.md): estilo, concorrência, erros, API pública
- [testes.md](testes.md): pirâmide de testes, *goldens*, *fuzz*, *benchmarks*
- [performance.md](performance.md): orçamentos e regras do caminho quente
- [pr-e-revisao.md](pr-e-revisao.md): PRs, revisão e *definition of done*
- [documentacao.md](documentacao.md): o que documentar e quando atualizar

## Skills de terceiros adotadas (revisadas em 2026-11-14)
| Skill | Origem | Commit | Licença | Local |
|---|---|---|---|---|
| `swift-concurrency-pro` | [twostraws/Swift-Concurrency-Agent-Skill](https://github.com/twostraws/Swift-Concurrency-Agent-Skill) | `bee3f69` | MIT | `.claude/skills/swift-concurrency-pro/` |
| `swift-testing-expert` | [AvdLee/Swift-Testing-Agent-Skill](https://github.com/AvdLee/Swift-Testing-Agent-Skill) | `798e9b1` | MIT | `.claude/skills/swift-testing-expert/` |

Avaliadas e **não adotadas**: AvdLee Swift-Concurrency (foco em app/Core Data; sobreposta) e twostraws Swift-Testing (redundante). Cópias sem modificação; ADR/standards prevalecem (overrides em `caju-swift-quality`). Atualizar uma skill de terceiros exige PR que revise o diff e troque o commit fixado.

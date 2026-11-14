# ADR 0009: M-1, qualidade e padrões antes de qualquer trabalho de engine

**Status:** Aceito (decisão do dono).

## Contexto
Várias sessões em paralelo vão escrever código e documentação. Sem padrões, testes e regras de documentação definidos antes, cada sessão inventa o seu e a documentação envelhece.

## Decisão
- Existe um passo **M-1**, **antes do M0**, que entrega: `CLAUDE.md`; `docs/standards/` (código, testes, performance, PR e *definition of done*, documentação); skills do projeto em `.claude/skills/` (`caju-docs-sync`, `caju-swift-quality`, `caju-testing`, `caju-new-module`).
- **Nenhum trabalho de engine começa antes de o M-1 ser aceito** (merge).
- **Documentação viva é regra:** toda mudança que altere comportamento, API, arquitetura, decisão, métrica ou processo atualiza docs/ADRs/standards **no mesmo PR** (skill `caju-docs-sync`, definition of done).
- **Skills e specs de terceiros:** avaliar candidatas úteis (formatadores, linters, guias de Swift/concorrência, skills públicas) **antes de adotar**: ler o conteúdo, checar licença e origem; adotar só o que for revisado e fixar a versão. Nada é baixado e executado sem revisão. O M-1 inicial entrega as skills próprias; a avaliação de terceiros é parte do M-1 e pode acrescentar itens.
- No M0, o CI passa a **impor** o que for automatizável (swift-format, lint, `-warnings-as-errors`, TSan, tamanho, benchmarks).

## Consequências
Pequeno atraso antes do M0, em troca de consistência desde o primeiro commit. Padrões mudam por PR (com ADR se for decisão).

## Quando reabrir
Se os padrões travarem o ritmo ou se ferramentas melhores surgirem.

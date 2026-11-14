# Performance: orçamentos e regras

Metas medidas nos aparelhos de referência (Galaxy S22, iPhone 16 Pro; ADR 0007). Estimativas `(?)` até medir.

- **ECS:** ≥ 100 000 entidades com 3 componentes por consulta em < 2 ms no aparelho alto; `spawn` ≥ 1 milhão/s.
- **Layout de UI:** 1 000 nós em < 1 ms de CPU com árvore estável; UI de tela cheia ≤ 1,5 ms CPU/quadro.
- **Draw calls:** ≤ 300 por quadro; UI ≤ 40.
- **Memória:** GPU ≤ 300 MB; residente ≤ 600 MB no cenário de referência.
- **Sem travadas:** nenhum quadro > 50 ms por compilação de pipeline, upload de textura ou carga de asset.
- **Quadro sem mudança** de UI custa só uma checagem de sujeira.

## Regras
1. Nenhuma alocação por quadro no caminho quente (verificado por inspeção de SIL/instrumentação em testes dos módulos quentes).
2. Todo módulo com meta tem *benchmark* no CI desde a primeira versão.
3. Otimização só com *benchmark* antes e depois no PR.
4. Harness: `swift run -c release caju-bench` (JSON). O gate de 10 % só liga com linha de base de aparelho; números de runner de CI não são de referência.
5. Tamanho de binário e tempo de compilação incremental medidos no CI; regressões aparecem no PR.

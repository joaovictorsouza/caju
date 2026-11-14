# Adendo: liberdade para divergir do rascunho

O dono do projeto esclareceu que o rascunho é só ponto de partida: **qualquer restrição dele pode ser trocada se a alternativa for melhor para o projeto**. Este adendo ajusta `planejamento-engine.md` e prevalece sobre ele onde houver conflito.

## Restrições do rascunho que deixam de ser obrigatórias

| Restrição | Posição anterior do plano | Nova posição |
|---|---|---|
| Só `FoundationEssentials` (P2/§3.1) | Preferir | **Foundation completo é permitido** onde o custo/benefício compensar (rede, datas, formatação, I/O). Regra mantida: **nenhum Foundation no caminho quente** (ECS, render, layout, animação). Medir tamanho de binário em CI. |
| Lista fechada de dependências (LANG-002) | Lista curta | **Dependências externas são permitidas** com critério: licença permissiva, versão fixa, mantida, compila em iOS/Android/macOS/Linux, custo de binário medido. Candidatas já avaliadas: `swift-nio`, `swift-atomics`, `swift-collections`, `swift-algorithms`, `swift-argument-parser` (tools), HarfBuzz, FreeType, meshoptimizer, KTX/Basis, Luau. |
| Swift puro (LANG) | Swift com deps C/C++ | **Código C/C++/Rust é aceito** quando for claramente melhor (ex.: shaping, compressão, BVH madura, runtime de scripts). Encapsular em targets SwiftPM com API Swift idiomática por cima. |
| WebGPU como RHI padrão (RHI-002) | Contra | Reavaliar sem preconceito: decidir D1 por **protótipo medido** (tamanho, tempo de quadro, memória) comparando RHI próprio Metal/Vulkan vs `wgpu-native`/Dawn. |
| Plataformas (PLAT-001) | iOS, Android, macOS | Pode incluir **visionOS/tvOS/Windows/Linux com GPU** se o RHI escolhido tornar o custo baixo; não são metas da v1. |
| Inexistência de editor (§1.2) | Fora do escopo | Um **inspector/depurador em tempo de execução** (reflexão do ECS) é recomendado cedo; editor visual fica avaliado após o vertical slice. |
| Sem scripting (§1.2) e sem código baixado (NFR-030) | Reescrever NFR-030 | Scripting passa a ser **objetivo de longo prazo**; ver §8 do plano. |
| Estrutura de camadas de UI (§14) | Já reduzida | Qualquer estrutura é aceitável se a **API pública for a DSL declarativa** e o custo por quadro parado for ~zero. |
| Nomes, módulos, IDs de requisito | Mantidos | Podem ser reorganizados; os IDs servem de rastreio, não de contrato. |

## Efeito prático no plano
1. **Fase 0** deve incluir um **ADR de política de dependências** com o critério acima (substitui LANG-002).
2. **D1 (GPU)** vira um *spike* de 1–2 sessões na Onda 1 (T3), com critérios numéricos de decisão, em vez de uma decisão prévia.
3. Onde o plano dizia "evitar Foundation", ler "evitar no caminho quente; permitido nas bordas".
4. Quaisquer propostas de melhoria vindas de revisão externa (incluindo a discussão de arquitetura pedida ao modelo Argon) entram como ADR; nada precisa de justificativa de aderência ao rascunho, só de **benefício mensurável para o projeto**.

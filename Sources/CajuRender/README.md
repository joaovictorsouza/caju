# CajuRender

Renderização: mundo de render separado, extração a partir do ECS, *frame graph* de cena, draw list, materiais e luz.

- **Camada:** 3 (dependências só para baixo; ver §5 do plano).
- **Trilha dona:** R-1 (Onda 1), dividida em R-1a e R-1b.
- **Estado:** **contrato publicado em PR draft** ([ADR 0023](../../docs/adr/0023-mundo-de-render-e-extracao.md), proposto; [briefs/r-1-contrato.md](../../docs/briefs/r-1-contrato.md)). Só tipos de valor puros: `CajuRenderMeshID`/`CajuRenderMaterialID`, `CajuMaterialParams` (`unlit`/`pbr`), `CajuDirectionalLight`, `CajuDrawKey`, `CajuDrawItem`. A extração, o `CajuRenderWorld`, o frame graph de cena, a sombra, o instancing e o skinning ainda **não existem**.

## Contrato em uma página
1. **Extração:** no fim do quadro, copia do ECS (`CajuGlobalTransform` + `CajuRenderMesh`) para o mundo de render; o desenho nunca lê o ECS.
2. **Draw list:** vetor de `CajuDrawItem` ordenado por `CajuDrawKey` (fila | pipeline | material | profundidade); opacos frente-para-trás, `blend` trás-para-frente.
3. **Frame graph de cena:** `shadow` (R-1b) → `main` (forward + MSAA transitório) → UI → *backbuffer*, sobre o `CajuFrameGraphBuilder` do RHI.
4. **A-1:** `CajuRender` não depende de `CajuAssets`; uma cola da aplicação traduz handle de asset (com estados `.loading`/`.ready`/`.failed`) em ids de render.
5. **AN-1:** R-1b recebe `CajuSkinPose` (paleta de skinning pronta, espaço do modelo).

## Divisão
- **R-1a:** extração, unlit/PBR simples, luz direcional, câmera, cull, PSO em memória.
- **R-1b:** 1 sombra, instancing, skinning, PSO persistido.

## Limites conhecidos
Uma luz direcional, sem IBL, sem luzes pontuais, sem *blend shapes*; metas de desempenho `(?)` (ver `docs/standards/performance.md`).

## Dependências
- `CajuCore`
- `CajuMath`
- `CajuRHI`
- `CajuScene`

## Como testar
`swift test` na raiz (`Tests/CajuModulesTests/CajuRenderContractTests.swift`); roda em Linux e macOS sem GPU.

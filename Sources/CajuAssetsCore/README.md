# CajuAssetsCore

Parsers puros de assets: **bytes → dados validados**. Swift puro, **sem Foundation**; erros tipados (`throws(AssetError)`); limites (`AssetLimits`) verificados **antes de alocar**. Decisões: [ADR 0017](../../docs/adr/0017-parsers-de-assets-puros.md).

- **Camada:** 1 (dependências só para baixo; ver §5 do plano).
- **Trilha dona:** P-2.
- **Estado:** implementado (glTF/GLB, KTX2 parse, PNG, JPEG cabeçalho, meshopt).

## API pública
| Tipo | O que faz |
|---|---|
| `AssetError`, `AssetLimits` | Erro tipado (`truncated`, `invalid`, `limitExceeded`, `unsupported`) e limites de entrada/saída/dimensão/JSON/mips |
| `GLTFParser.parse` → `GLTFDocument` | `.gltf` (JSON) ou `.glb`; valida accessors, bufferViews, buffers, meshes, nodes, scenes e limites; `accessorLayout(_:)` dá o layout validado. Não carrega `uri` externos nem `data:`; sparse accessors → `unsupported` |
| `KTX2Container.parse` | Cabeçalho, DFD, KVD e índice de níveis do KTX 2.0, tudo validado. **Não transcodifica** Basis (ETC1S/UASTC) nem descomprime Zstd/ZLIB: pendente de PR de dependência C dedicado |
| `PNGDecoder.readInfo` / `decode` | Todos os tipos/profundidades, filtros, Adam7, PLTE/tRNS, CRC e Adler verificados, inflate próprio com teto de saída; saída RGBA8 (16 bits reduzidos para 8) |
| `JPEGDecoder.readInfo` | Só metadados (dimensões, componentes, progressivo, subamostragem, orientação EXIF). **Não decodifica pixels** |
| `Meshopt` | Decodificação de vertex/index buffers e filtros (EXT_meshopt_compression), Swift puro. Índices não são validados contra a contagem de vértices (responsabilidade do consumidor) |

## Fora de escopo / pendências
- Transcodificação Basis/Zstd (dependência C, PR dedicado ao `Package.swift`).
- Decodificação de pixels JPEG.
- Alvo de testes dedicado (exige `Package.swift`); por ora os testes estão em `Tests/CajuModulesTests`.

## Dependências
- `CajuMath`
- `CajuCollections`

## Como testar
`swift test` na raiz. Os parsers têm testes unitários e *fuzz* determinístico (`CajuFuzz`/`CajuPCG32`; entradas aleatórias e mutadas, com limites pequenos).

# CajuAssetsCore

Parsers e decodificadores puros de assets: **bytes → dados validados**. Swift puro, **sem Foundation**; erros tipados (`throws(AssetError)`); limites (`AssetLimits`) verificados **antes de alocar**. Decisões: [ADR 0017](../../docs/adr/0017-parsers-de-assets-puros.md) e [ADR 0022](../../docs/adr/0022-jpeg-e-zstd-em-swift-puro.md).

- **Camada:** 1 (dependências só para baixo; ver §5 do plano).
- **Trilhas donas:** P-2 (base) e A-2 (pixels JPEG e Zstd).
- **Estado:** implementado (glTF/GLB, KTX2 parse + descompressão Zstd/ZLIB por nível, PNG, JPEG metadados + pixels RGBA8, Zstd, meshopt).

## API pública
| Tipo | O que faz |
|---|---|
| `AssetError`, `AssetLimits` | Erro tipado (`truncated`, `invalid`, `limitExceeded`, `unsupported`) e limites de entrada/saída/dimensão/JSON/mips |
| `GLTFParser.parse` → `GLTFDocument` | `.gltf` (JSON) ou `.glb`; valida accessors, bufferViews, buffers, meshes, nodes, scenes e limites; `accessorLayout(_:)` dá o layout validado. Não carrega `uri` externos nem `data:`; sparse accessors → `unsupported` |
| `KTX2Container.parse` / `decompressLevel` | Cabeçalho, DFD, KVD e índice de níveis do KTX 2.0 validados; `decompressLevel(_:from:limits:)` descomprime níveis `.none`, `.zstd` e `.zlib`. **Não transcodifica** Basis (`ETC1S`/`UASTC`): pendente de PR de dependência C dedicado |
| `ZstdDecoder.decompress` | Descompressor Zstandard (RFC 8878) puro em Swift: quadros padrão com blocos `raw`, `RLE` e `compressed` (Huffman e FSE), checksum `XXH64` opcional; recusa dicionários/quadros desconhecidos e verifica `expectedSize`/limites antes de alocar |
| `PNGDecoder.readInfo` / `decode` | Todos os tipos/profundidades, filtros, Adam7, PLTE/tRNS, CRC e Adler verificados, inflate próprio com teto de saída; saída RGBA8 (16 bits reduzidos para 8) |
| `JPEGDecoder.readInfo` / `decode` → `JPEGImage` | Metadados (`SOF0`/`SOF1`/`SOF2`, EXIF orientation) e decodificação completa de pixels RGBA8 (Huffman 8 bits baseline sequencial e progressivo, 1 e 3 componentes, subamostragem `4:4:4`/`4:2:2`/`4:2:0`, `RST`, EXIF apenas reportada; rejeita aritmético, 12 bits e CMYK) |
| `Meshopt` | Decodificação de vertex/index buffers e filtros (EXT_meshopt_compression), Swift puro. Índices não são validados contra a contagem de vértices (responsabilidade do consumidor) |

## Fora de escopo / pendências
- Transcodificação Basis (`ETC1S`/`UASTC`) para formatos comprimidos de GPU (dependência C, PR dedicado ao `Package.swift`).

## Dependências
- `CajuMath`
- `CajuCollections`

## Como testar
`swift test --filter CajuAssetsCoreTests` na raiz (ou `swift test`). Os parsers e decodificadores possuem testes unitários e *fuzz* determinístico em `Tests/CajuAssetsCoreTests/` (`CajuFuzz`/`CajuPCG32`; entradas aleatórias e mutadas, com limites pequenos).

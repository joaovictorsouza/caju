# ADR 0022: Decodificação de pixels JPEG e descompressão Zstd em Swift puro (A-2)

**Status:** Aceito (A-2, Onda 1; 2026-11-15). Substitui as decisões do [ADR 0017](0017-parsers-de-assets-puros.md) sobre **descompressão Zstd em C** e **pixels JPEG fora de escopo**; a **transcodificação Basis (ETC1S/UASTC)** continua dependente de biblioteca C em PR dedicado ao `Package.swift`.

## Contexto
A trilha A-2 precisa entregar pixels RGBA8 de imagens JPEG e descompressão das camadas de supercompressão Zstandard (`supercompressionScheme == 2`) do KTX2 no `CajuAssetsCore` (camada 1, puro, sem Foundation, iOS/Android/macOS/Linux). No ADR 0017, tanto a transcodificação Basis quanto a descompressão Zstd e os pixels JPEG haviam ficado para dependências C futuras, o que exigiria alteração no `Package.swift` trancado e empacotamento nativo por plataforma.

## Decisão
- **Pixels JPEG em Swift puro (`JPEGDecoder.decode`):** implementação completa em Swift puro, sem Foundation, suportando JPEG Huffman de 8 bits baseline/estendido sequencial (`SOF0`/`SOF1`) e progressivo (`SOF2`), 1 componente (cinza → RGBA8) e 3 componentes (YCbCr → RGBA8), subamostragem `4:4:4`/`4:2:2`/`4:2:0`, marcadores de reinício (`DRI`/`RST0...RST7`), IDCT inteira determinística em ponto fixo e orientação EXIF apenas reportada em `JPEGImage.exifOrientation` (não aplicada). Modos aritméticos, 12 bits e CMYK são rejeitados com `AssetError.unsupported`; `width * height * 4` e dimensões são verificados contra `AssetLimits` antes de alocar.
- **Descompressor Zstd em Swift puro (`ZstdDecoder.decompress`):** implementação da RFC 8878 em Swift puro, sem Foundation, suportando quadros padrão (`0xFD2FB528`) com blocos `raw`, `RLE` e `compressed` (literais Huffman de 1 e 4 fluxos com pesos diretos ou FSE; sequências com tabelas FSE predefinidas, comprimidas, RLE e repetidas) e verificação opcional de checksum `XXH64`. Dicionários, quadros ignoráveis/legados/desconhecidos e saídas acima de `expectedSize` ou `AssetLimits` são rejeitados antes de alocar.
- **Integração utilitária no KTX2:** `KTX2Container.decompressLevel(_:from:limits:)` descomprime níveis `.none`, `.zstd` e `.zlib` mantendo `KTX2Container.parse(_:limits:)` inalterado.
- **Transcodificação Basis (ETC1S/UASTC):** permanece fora de `CajuAssetsCore` em Swift puro e continua reservada para PR dedicado de dependência C no `Package.swift` (ADR 0005).

## Alternativas
- **Adicionar `libjpeg-turbo` e `libzstd` como targets C no `Package.swift`:** evita reimplementar codecs, mas aumenta a superfície de memória não segura em dado externo hostil, exige manutenção de build cruzado iOS/Android/macOS/Linux e altera o `Package.swift` trancado.
- **Deixar Zstd junto com Basis no PR de dependência C:** atrasaria o suporte a texturas KTX2+Zstd (ex.: UASTC supercomprimido ou formatos Vulkan não-Basis) que já podem ser descomprimidos na camada pura.

## Consequências
- `Package.swift` e CI permanecem inalterados; `CajuAssetsCore` continua 100% Swift seguro, sem Foundation, testado com *fuzz* determinístico em `Tests/CajuAssetsCoreTests`.
- O tamanho de binário extra é apenas código Swift compilado (não medido `(?)`), sem novos binários C/C++ por arquitetura.
- Apenas a transcodificação Basis (`.basisLZ` / UASTC → formatos de GPU) permanece pendente de dependência C.

## Quando reabrir
Se a medição de desempenho em aparelho de referência mostrar que a decodificação JPEG ou Zstd em Swift puro viola o orçamento de carga de assets (quadro > 50 ms por bloqueio ou gargalo de CPU em carga assíncrona), ou se a biblioteca C de Basis já incluir Zstd com ganho líquido relevante de tamanho/velocidade.

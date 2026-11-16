# ADR 0017: Parsers de assets em Swift puro (P-2); Basis fica para dependência C dedicada

**Status:** Aceito (parcialmente substituído pelo [ADR 0022](0022-jpeg-e-zstd-em-swift-puro.md) na parte de descompressão Zstd e decodificação de pixels JPEG; transcodificação Basis continua para dependência C).

## Contexto
A trilha P-2 entrega `CajuAssetsCore` (camada 1, puro, sem GPU/ECS). O ADR 0005 permite dependências C encapsuladas, mas cada uma exige PR dedicado ao `Package.swift`. Os parsers lidam com dado externo hostil e precisam rodar em iOS, Android, macOS e Linux, com *fuzz* no CI.

## Decisão
- **Swift puro, sem Foundation** em todo `CajuAssetsCore`: JSON mínimo próprio (glTF), inflate/zlib próprio (PNG), leitor de bytes com limites. Erros tipados (`throws(AssetError)`); limites (`AssetLimits`) verificados antes de alocar.
- **Meshopt decodificado em Swift puro** (porte do algoritmo do meshoptimizer, MIT), em vez de dependência C: portabilidade e nenhuma mudança em `Package.swift`. Só **decodificação** (não há encoder no runtime).
- **KTX2: só parse/validação** (cabeçalho, DFD, KVD, índice de níveis). **Transcodificação Basis (ETC1S/UASTC) e descompressão Zstd** exigem biblioteca C e ficam para um **PR de dependência dedicado** (ADR 0005: licença, versão fixa, tamanho medido).
- **JPEG: só cabeçalho/metadados** (dimensões, componentes, progressivo, EXIF orientation). Decodificação completa fica fora desta trilha.
- Testes de `CajuAssetsCore` ficam em `CajuModulesTests` até existir alvo de testes dedicado (mudança de `Package.swift`, PR dedicado).

## Consequências
- Nenhuma dependência nova; superfície de ataque restrita a Swift seguro.
- O consumidor (`CajuAssets`) precisa de transcodificador Basis e decodificador JPEG antes de usar texturas KTX2 Basis e JPEG em pixels.

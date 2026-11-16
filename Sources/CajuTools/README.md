# CajuTools

CLI `caju-tools` (executável de host da engine): ferramentas de preparação e validação offline de assets.

- **Trilha dona:** T-1 (Onda 1). **Estado:** implementado (`texture`, `validate-gltf`, `manifest`).
- **Camada:** 4 (ferramenta de host, fora do binário do jogo e do build Android).
- **Dependências atuais:** apenas `Foundation` (sem dependências internas/externas enquanto `Package.swift` estiver trancado).

## Subcomandos e uso

```sh
swift run caju-tools --help
```

Códigos de saída:
- `0`: sucesso (ou `--help`/`-h`).
- `1`: entrada inválida, truncada, limite excedido, recurso não suportado ou erro de E/S.
- `2`: erro de uso da linha de comando (subcomando desconhecido, opção inválida ou argumento ausente).

### `texture`
Converte imagens `PNG` (todos os tipos de cor padrão, filtros 0..4, Adam7, PLTE/tRNS) ou `PPM P6` para KTX 2.0 e valida o cabeçalho/contêiner gerado.

```sh
swift run caju-tools texture entrada.png -o saida.ktx2 [--format rgba8-srgb|rgba8-unorm] [--mipmaps]
swift run caju-tools texture --validate arquivo.ktx2
```

> [!NOTE]
> **Limitação conhecida (ASTC):** sem dependência C / encoder ASTC externo ([ADR 0017](../../docs/adr/0017-parsers-de-assets-puros.md)), a codificação ASTC real não está disponível neste alvo. Por isso `texture` gera KTX 2.0 não comprimido em `RGBA8` (`VK_FORMAT_R8G8B8A8_SRGB = 43` por padrão, ou `VK_FORMAT_R8G8B8A8_UNORM = 37`), preenche DFD RGBSDA v1.3 e KVD determinístico (`KTXwriter = caju-tools`), e executa validação estrita do cabeçalho, DFD, KVD e índice de níveis. Passar `--format astc-4x4` falha explicitamente com erro tipado (`unsupported`, saída `1`).

### `validate-gltf`
Valida arquivos glTF 2.0 (`.gltf`) e GLB v2 (`.glb`) manualmente com `Foundation` (JSON com pré-checagem de UTF-8 e profundidade máxima, versão `"2.x"`, `buffers`, `bufferViews`, `accessors` dentro dos limites e alinhamentos, `materials`, `textures`, `samplers`, `skins`, `meshes`, hierarquia acíclica de `nodes` e `scenes`).

```sh
swift run caju-tools validate-gltf modelo.glb [--json]
```

### `manifest`
Percorre um diretório de assets de forma determinística (ordem UTF-8 por caminho relativo com `/`, ignorando `.DS_Store`, `.git` e links simbólicos, sem timestamps) e emite JSON com chaves ordenadas contendo `path`, `size` e `sha256`.

```sh
swift run caju-tools manifest ./assets [-o manifesto.json]
```

## Arquitetura interna

O ponto de entrada (`Sources/CajuTools/main.swift`) é separado da lógica pura, que vive em `Sources/CajuToolsCore/` (testada por `Tests/CajuToolsTests` com `@testable import`):
- `main.swift`: apenas lê `CommandLine.arguments`, chama `CajuToolsCLI.run` e encerra com `0`/`1`/`2`.
- Em `CajuToolsCore`: `CLI.swift`, `ToolsError.swift`, `ToolsSupport.swift`: roteamento, erros tipados (`CajuToolsError`), limites (`ToolsLimits`), leitor/escritor de bytes seguro, `ToolsSHA256` e serializador JSON determinístico.
- `DeflateInflate.swift`, `PNGImageDecoder.swift`, `KTX2Texture.swift`: decodificação de imagens, geração e validação estrita de KTX 2.0.
- `ValidateGLTFCommand.swift`: validador glTF 2.0 / GLB v2.
- `ManifestCommand.swift`: varredura determinística e geração de manifesto.

## Como testar

Testes nativos (Swift Testing) em `Tests/CajuToolsTests`: `swift test --filter CajuToolsCLITests`. Os testes de *golden*, determinismo (2 execuções comparadas byte a byte) e *fuzz* determinístico ficam no script abaixo, com entradas em `Tests/CajuToolsGoldens/`:

```sh
scripts/test-caju-tools.sh
```

## Mudanças futuras de `Package.swift`
- (Feito na integração da Onda 1: `CajuToolsCore` + `CajuToolsTests`.)
- Opcionalmente adicionar dependência de `CajuAssetsCore` (reuso do parser glTF/PNG/KTX2 sem duplicação), `swift-argument-parser` e/ou encoder ASTC C encapsulado (seguindo ADR 0005).

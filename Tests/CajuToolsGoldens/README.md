# CajuToolsGoldens

Entradas de teste e saídas esperadas (*goldens*) para a CLI `caju-tools` (trilha T-1).

Este diretório existe fora de `Package.swift` porque `CajuTools` é um executável sem alvo de testes dedicado até o PR de `Package.swift` da Onda 1.

## Estrutura
- `inputs/`: amostras determinísticas (`valid.gltf`, `valid.glb`, `invalid-*.gltf`, `sample.png`, `manifest_tree/`).
- `expected/`: saídas exatas esperadas de `stdout` e arquivos binários gerados (`sample.ktx2`, `manifest.json`).

## Como executar
```sh
scripts/test-caju-tools.sh
```

O script valida códigos de saída (`0` ok, `1` inválido, `2` uso), compara saídas com os *goldens*, checa determinismo executando duas vezes cada subcomando e executa 281 casos de *fuzz* com semente fixa (`20261115`).

# CajuTools

CLI `caju-tools` (executável do pacote): `texture` (KTX2/ASTC), `validate-gltf` e `manifest`.

- **Trilha dona:** T-1 (Onda 1). **Estado:** só o esqueleto da S-0 (uso e códigos de saída); os subcomandos são da T-1.
- **Dependências:** nenhuma ainda. A T-1 pode usar `CajuAssetsCore` e `CajuMath`; `swift-argument-parser` (candidata do ADR 0005) só entra por PR de `Package.swift`.
- Ferramenta de host: fora do binário do jogo e do build Android.

```sh
swift run caju-tools --help
```

# ADR 0005: Política de dependências e Foundation

**Status:** Aceito. Substitui LANG-002 do rascunho.

## Decisão
- **Foundation completo é permitido** nas bordas (rede, datas, formatação, I/O). **Proibido no caminho quente** (ECS, render, layout, animação). Medir tamanho de binário no CI.
- **Dependências externas são permitidas** se: licença permissiva, versão fixada, mantida, compila em iOS/Android/macOS/Linux, custo de binário medido.
- **C/C++/Rust aceitos** quando claramente melhores, encapsulados em targets SwiftPM com API Swift idiomática. Candidatas: `swift-nio`, `swift-atomics`, `swift-collections`, `swift-argument-parser`, HarfBuzz, FreeType, meshoptimizer, KTX/Basis, `miniaudio` (áudio; CoreAudio + AAudio), Luau (futuro).
- Áudio: **`miniaudio`** em vez de mixer próprio.
- Física no MVP: só BVH de consultas própria; reavaliar Jolt/embree se física dinâmica entrar.

## Ressalva
O teto de `.apk` ≤ 18 MB proposto para o gate é um número sem fonte e pode ser incompatível com o ICU do Foundation completo no Android: **medir antes de virar critério**.

## Aplicação (S-0, Onda 1)
- `miniaudio` entrou como target C `CMiniaudio`, **0.11.26** (tag `0.11.26`, cabeçalho único sem modificações, hash em `Sources/CMiniaudio/VERSION`), `MA_NO_ENCODING`; só o `CajuAudio` depende dele. Compila no Mac (host) e no Android arm64 (API 29). Custo de binário: medir quando a AU-1 o importar (hoje nada o referencia).
- HarfBuzz/FreeType **não** entraram: aprovados pelo dono, mas só por PR dedicado se a U-1 provar que o shaper puro não basta para latino.
- `swift-argument-parser` **não** entrou: o `caju-tools` começa sem dependências; a T-1 pede por PR de `Package.swift` se precisar.

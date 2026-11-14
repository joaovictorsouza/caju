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

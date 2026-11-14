# CajuText

Texto: leitura de fonte, shaping, medida, quebra de linha, atlas MSDF e modelo de edição.

- **Camada:** 1 (puro; dependências só para baixo, ver §5 do plano).
- **Trilha dona:** P-5. Decisões: [ADR 0011](../../docs/adr/0011-texto-p5.md).
- **Estado:** implementado para texto latino do MVP; sem dependências C.

## API pública
| Tipo | Papel |
|---|---|
| `CajuFont` | Leitor TrueType com limites verificados: `cmap`, avanços, contornos (`CajuOutline`) |
| `CajuTextShaper` / `CajuBasicShaper` | Escalares → glifos. O básico não faz kerning/ligaduras; o HarfBuzz virá implementar o protocolo |
| `CajuTextLayout` | Medida, quebra (espaços, hífen, ZWSP, `\n`; palavra maior que a linha quebra por caractere), alinhamento, cursor e *hit-testing* |
| `CajuMSDF` | Gera MSDF RGBA8 de um contorno (coloração de arestas + pseudo-distância) |
| `CajuGlyphAtlas` | Atlas MSDF em bitmap de CPU (prateleiras, sob demanda, `dirtyRect`) |
| `CajuTextEditorModel` | Conteúdo, cursor/seleção por grafema, palavras, IME (texto marcado), `maxLength` |

```swift
let font = try CajuFont(data: bytes)
let layout = CajuTextLayout(text: "olá", shaper: CajuBasicShaper(font: font),
                            style: .init(fontSize: 16, maxWidth: 120))
var atlas = try CajuGlyphAtlas(font: font)
let glyph = try atlas.glyph(layout.glyphs[0].glyph)   // retângulo no atlas + plano do quad
```

## Limitações conhecidas
Sem kerning/GPOS, OpenType CFF, RTL/CJK/emoji (v1.0). Sem correção de erro do MSDF. Layout e atlas alocam: recalcule só quando texto/estilo mudam. Benchmark de medida/atlas pendente `(?)` (`caju-bench` depende do `Package.swift`, trancado).

## Como testar
Os testes ficam em `Tests/CajuTextTests` (fonte de teste gerada em memória; *fuzz* do parser de fonte e do layout). Rodam com `swift test --filter CajuTextTests` assim que o alvo `CajuTextTests` existir no `Package.swift` (PR dedicado).

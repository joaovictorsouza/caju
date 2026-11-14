# ADR 0012: Texto do MVP (P-5): fonte TrueType em Swift puro, shaper plugável e MSDF em CPU

**Status:** Aceito.

## Contexto
A trilha P-5 (`CajuText`) precisa entregar shaping, medida, quebra de linha, atlas MSDF e o modelo do `TextEditor` sem GPU e sem tocar `Package.swift` (trancado). HarfBuzz/FreeType (ADR 0005) entram por PR dedicado e curto.

## Decisão
- **`CajuTextShaper` é o ponto de extensão.** `CajuTextLayout` (medida, quebra, alinhamento, cursor, *hit-testing*) depende só do protocolo. O backend HarfBuzz, quando chegar, implementa o protocolo (kerning, ligaduras, scripts complexos) sem mudar layout nem atlas.
- **Enquanto isso, `CajuBasicShaper` + `CajuFont`:** leitor TrueType (`glyf`) em Swift puro, com limites verificados em toda leitura (`head`, `maxp`, `hhea`, `hmtx`, `cmap` 4/12, `loca`, `glyf` simples e compostos), erros tipados e *fuzz*. Cobre texto latino do MVP; não cobre CFF/OpenType, GPOS/kerning nem RTL/CJK/emoji (v1.0).
- **MSDF em bitmap de CPU (`CajuMSDF`, `CajuGlyphAtlas`):** coloração de arestas e pseudo-distância como no msdfgen, sem correção de erros por ora; atlas RGBA8 por prateleiras, glifos sob demanda, `dirtyRect` para upload.
- **Offsets:** o layout usa escalares Unicode; `CajuTextEditorModel` usa grafemas e converte entre os dois.

## Alternativas
Esperar HarfBuzz/FreeType antes de qualquer código (bloquearia a trilha e os testes); geração de MSDF na GPU (fora do escopo de CPU puro da camada 1).

## Consequências
Os testes rodam em Linux e macOS sem dependências C. A fonte de teste é gerada em memória (`Tests/CajuTextTests/TestFont.swift`), sem binários versionados. Rodar `Tests/CajuTextTests` exige o alvo `CajuTextTests` no `Package.swift`, que vai em PR dedicado (patch de uma linha pronto).

## Quando reabrir
Quando o PR de HarfBuzz/FreeType entrar (decidir se o leitor Swift permanece como *fallback* ou sai); se o custo de geração de MSDF por glifo `(?)` não couber no orçamento de quadro.

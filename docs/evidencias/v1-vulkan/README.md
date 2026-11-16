# Evidências da V-1 (backend Vulkan) no Galaxy S22+

Aparelho: Samsung Galaxy S22+ (SM-S906E, Adreno 730, Android 16). Comando: `Hosts/Android/scripts/run-conformance.sh`
(toolchain swift.org 6.4.2, NDK r30, build de depuração).

## Conformidade do RHI
| Data | Fatia | Resultado | Arquivo |
|---|---|---|---|
| 2026-11-15 | C | 2/6 (os casos de recurso: `textureUploadRoundTrip`, `destroyedHandlesAreRejected`); os 4 de render esperam a fatia D | [conformance-c.txt](conformance-c.txt) |
| 2026-11-15 | D | **6/6**: os 4 casos de render (triângulo, MSAA 4x resolvido, cull/sentido, validação igual ao null) passam com os mesmos valores esperados do Metal | [conformance-d.txt](conformance-d.txt) |

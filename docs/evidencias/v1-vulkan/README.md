# Evidências da V-1 (backend Vulkan) no Galaxy S22+

Aparelho: Samsung Galaxy S22+ (SM-S906E, Adreno 730, Android 16). Comando: `Hosts/Android/scripts/run-conformance.sh`
(toolchain swift.org 6.4.2, NDK r30, build de depuração).

## Conformidade do RHI
| Data | Fatia | Resultado | Arquivo |
|---|---|---|---|
| 2026-11-15 | C | 2/6 (os casos de recurso: `textureUploadRoundTrip`, `destroyedHandlesAreRejected`); os 4 de render esperam a fatia D | [conformance-c.txt](conformance-c.txt) |

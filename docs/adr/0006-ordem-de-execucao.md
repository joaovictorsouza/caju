# ADR 0006: Ordem de execução

**Status:** Aceito. Substitui "Fase 0 + 8 trilhas cegas".

## Contexto
"Contratos antes de código" para 8 subsistemas é waterfall: contratos de RHI/texto/UI só sobrevivem ao primeiro contato com a GPU, e a integração quebraria 8 branches ao mesmo tempo.

## Decisão
1. **M0** (1 sessão): `Package.swift` com todos os targets declarados (trancado), CI Linux/macOS, host iOS/macOS, tipos primitivos de `CajuMath`, convenções, CODEOWNERS.
2. **Onda 0.5** em paralelo:
   - **Tracer bullet:** TB-1 (Core/ECS mínimo + Scene) e TB-2 (Platform + RHI + Metal + um botão com texto em aparelho real).
   - **Núcleos puros de CPU (sem GPU/ECS, contrato estável):** P-1 Math, P-2 parsers glTF/KTX2/meshopt (+ fuzz), P-3 BVH, P-4 UI layout, P-5 texto (shaping + atlas MSDF em bitmap de CPU).
   - **TB-Android** (trilha separada, limite de 5 dias; **revisado para 3 dias pelo [ADR 0011](0011-kill-criteria-tb-android.md)**): Gradle/CMake/JNI/`libswiftCore.so`, Vulkan próprio + VMA no Galaxy S22. Se o Swift no Android travar, iOS/macOS e módulos puros seguem sem esperar. **Kill-criteria** explícitos a definir antes do início.
3. **Gate de saída** (proposta; números a calibrar por aparelho de referência):
   - 50 ciclos de background/resume, rotação e recriação de superfície: ΔRSS ≤ 1 MB e zero erro de validação.
   - Soak de 5 min com cenário definido por aparelho, p95 < 16 ms, com degradação controlada (não "zero throttling").
   - TSan limpo em Linux/macOS; SIL do `Query` sem alocação.
   - `Observation` funcionando em aparelho Android real.
   - Compilação incremental de módulo ≤ 5 s.
   - Tamanho de `.apk`: a medir (ver ADR 0005).
4. **Onda 1:** Assets+ECS, Render completo, Input, UI integrada, Anim, Physics, Audio, Tools.
5. **Vertical slice medido** e depois v1.0 e opcionais (camera rig, scripting, etc.).

## Regras de paralelismo (mantidas)
Um diretório = um dono; `Package.swift` trancado; mudança de API cruzando módulos por PR de contrato; sem arquivos "Utils"; gerados em `Generated/`; PRs pequenos.

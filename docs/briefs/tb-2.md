# Brief TB-2: Platform, RHI e Metal

Formato da skill `caju-track-brief`. Números marcados `(?)` não foram medidos.

1. **Trilha e marco:** TB-2 (plano §8, Onda 0.5), rumo ao marco M2 (cubo texturizado e botão com texto no iPhone 16 Pro). Sustentada pelos ADRs 0001 (RHI próprio), 0005 (Foundation), 0006 (ordem e gate), 0007 (aparelhos) e 0015 (contrato do RHI e da Platform, escrito nesta trilha).
2. **Diretórios que possuo:** `Sources/CajuPlatform`, `Sources/CajuRHI`, `Sources/CajuRHIMetal`, `Hosts/Apple`, `docs/briefs/tb-2.md` e os testes correspondentes. **Não toco:** `Package.swift`, CI, `CajuCore`, `CajuMath`, `CajuRHIVulkan` (TB-Android), demais módulos. Sem alvo de teste novo (exigiria `Package.swift`): os testes entram em `Tests/CajuModulesTests`, alvo existente que já depende de `CajuRHI`, `CajuPlatform` e `CajuRHIMetal`.
3. **Contrato:**
   - `CajuRHI` (deps: `CajuCore`, `CajuMath`; sem Foundation): handles numéricos geração+índice, descritores, formatos (inclui ASTC), capabilities, `CajuRenderDevice`/`CajuQueue`/`CajuCommandBuffer` e encoders `~Copyable` (render, compute, copy), `CajuSwapchain` e recriação de superfície, `CajuUploadBudget`, *frame graph* (declaração, compilação, aliasing de transientes, execução) e backend `CajuNullDevice` para testes headless.
   - `CajuPlatform` (deps: `CajuCore`): superfície nativa, ciclo de vida (máquina de estados), fila de eventos, laço principal (`CajuMainLoop`) puro e testável, protocolos `CajuApplication` (lado do jogo) e `CajuPlatformHost` (lado da plataforma).
   - Erros tipados `throws(CajuRHIError)`; sem `!`, `try!`, `fatalError`, `precondition`.
4. **Entregas e critérios de pronto:**
   - **Fase 1 (contrato):** API pública com DocC, READMEs dos módulos, ADR 0015, testes headless do *frame graph* e do laço/ciclo de vida, `swift build`, `swift test`, `swift format lint --strict`, `scripts/check-forbidden.sh`. PR draft publicado cedo (a TB-Android depende do contrato).
   - **Fase 2:** `CajuRHIMetal` (render pass, transient/memoryless, MSAA, frame graph); shaders Slang → MSL offline (se exigir ferramenta/dependência nova: documentar e parar para PR dedicado); `CajuPlatform` Apple (UIKit/AppKit, `CAMetalLayer`); `Hosts/Apple` com cubo e botão com texto simples no iPhone 16 Pro (ou simulador).
   - **Fase 3:** *goldens* Metal (conformidade), 50 ciclos de background/resume e recriação de superfície sem vazamento (gate: ΔRSS ≤ 1 MB, zero erro de validação), *benchmark* de CPU do *frame graph*, medições reais, docs sincronizados.
5. **Riscos e kill-criteria:**
   - `~Copyable` em protocolos com tipos associados e `Span` (exige iOS 26 em runtime) conflitam com o piso iOS 17: contrato usa `UnsafeRawBufferPointer` nas bordas de upload (ADR 0015).
   - Slang exige ferramenta externa (`slangc`) fora do toolchain: se não houver binário reproduzível, a Fase 2 usa MSL escrito à mão como *stand-in* documentado e abre PR dedicado para a ferramenta.
   - Sem aparelho conectado, a validação da Fase 2/3 roda no simulador e os números de aparelho ficam `(?)`.
   - Kill-criteria: se o contrato genérico (sem `any`) travar o compilador 6.2, recuar para encoders por *closure* com tipos concretos por backend e registrar no ADR 0015.
6. **Documentos que vou atualizar:** ADR 0015 + `docs/adr/README.md`, plano (§1, §8, §9, §10, §11), `docs/standards/testes.md` e `performance.md` (quando houver medição), READMEs de `CajuPlatform`, `CajuRHI`, `CajuRHIMetal`, `Hosts/Apple`.
7. **Pré-requisitos:** M-1 aceito e M0 entregue (merge do PR #2 em `main`). TB-2 não depende de outras trilhas; a TB-Android depende da Fase 1.

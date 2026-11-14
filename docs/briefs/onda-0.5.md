# Briefs das trilhas da Onda 0.5 (proposta)

Formato da skill `caju-track-brief`. Base: plano §8, ADR 0006, ADR 0010. Pré-requisitos cumpridos: M-1 aceito, M0 entregue (após o merge do PR do M0). Toda trilha: `Package.swift` e CI **não** se tocam (PR dedicado); segue `caju-new-module`, `caju-swift-quality`, `caju-testing`, `caju-docs-sync`. Números marcados `(?)` não foram medidos.

**Divisão de consumo (regra do dono):** código comum (parsers, matemática, layout, testes) → Antigravity com modelo **Hydrogen**; raciocínio pesado (desenho de API do `Query`/agendador, RHI/frame graph, Vulkan) → **Argon** ou Claude. Se o Claude se aproximar do limite de 5 h/semanal, mover mais trilhas para o Antigravity. Sugestão inicial: P-1, P-2, P-3, P-4 → Hydrogen; P-5, TB-1 → Argon/Claude; TB-2 → Claude; TB-Android → Claude (precisa de aparelho/Mac; Remote Control).

| Trilha | Dono (diretórios) | Entrada → saída | Pronto quando | Executor sugerido |
|---|---|---|---|---|
| **TB-1** | `Sources/CajuCore`, `Sources/CajuScene` (+ testes) | — → ECS híbrido, `Query` (packs com fallback), agendador single-thread com validação de acesso, mensagens, estados, tempo, `@Component`, Transform/hierarquia | Testes headless; SIL do `Query` sem alocação; benchmark ECS (meta NFR-008 `(?)`); TSan limpo; ADR 0003 atualizado se divergir | Argon/Claude |
| **TB-2** | `CajuPlatform`, `CajuRHI`, `CajuRHIMetal`, `Hosts/Apple` | Janela/superfície → RHI com render pass, transient e frame graph; Slang → MSL; cubo e botão com texto no iPhone 16 Pro | Goldens Metal; ciclos de background/resume sem vazamento; M2 | Claude (Mac via Remote Control) |
| **TB-Android** | `CajuRHIVulkan`, parte Android de `CajuPlatform` | Gradle/CMake/JNI/`libswiftCore.so`, Game Thread (ADR 0008), Vulkan + VMA no S22+ Snapdragon | **Timebox 5 dias.** Kill-criteria a definir pelo dono antes de começar (proposta: sem janela Swift desenhando um triângulo no S22+ no dia 3, ou sem `.apk` rodando no dia 5 ⇒ parar e reabrir ADR 0001/0008) | Claude |
| **P-1** | `CajuMath`, `Tests/CajuMathTests` | Primitivos do M0 → SIMD completo, inversa/decomposição, interseções, cor, easing | Testes de propriedade ≥ 10 000 casos, tol. 1e-5; benchmark em `caju-bench`; sem Foundation | Hydrogen |
| **P-2** | `CajuAssetsCore` | Bytes → glTF validado, KTX2/Basis, meshopt, PNG/JPEG; `throws(E)` | Fuzz sem crash/OOB/alocação acima do limite; limites antes de alocar; dependências C via PR dedicado ao `Package.swift` (ADR 0005). **Estado:** glTF/GLB, KTX2 (só parse), PNG, JPEG (só cabeçalho) e meshopt (Swift puro) implementados; pendentes: transcodificação Basis/Zstd (dependência C) e pixels JPEG ([ADR 0017](../adr/0017-parsers-de-assets-puros.md)) | Hydrogen |
| **P-3** | `CajuPhysicsSpatial` | AABB/triângulos → BVH dinâmica, raycast/shapecast/sobreposição | Testes de propriedade contra força bruta; benchmark de construção/consulta `(?)` | Hydrogen |
| **P-4** | `CajuUILayout` | Árvore retida + protocolo de layout → frames; stacks, ZStack, frame, Spacer, hit-testing | 1 000 nós < 1 ms `(?)` (NFR-009); sem alocação em árvore estável | Hydrogen |
| **P-5** | `CajuText` | Strings + fonte → glifos, medida, quebra de linha, atlas MSDF em bitmap de CPU, modelo do `TextEditor` | Goldens de medida/quebra; fuzz de fontes; HarfBuzz/FreeType via PR dedicado | Argon/Claude |

## Contrato comum
Dependências só para baixo; API pública mínima; DocC; `README.md` do módulo atualizado; nenhuma trilha toca outra trilha. Mudança de contrato entre módulos: PR de contrato antes do uso.

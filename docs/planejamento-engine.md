# Caju: planejamento da engine 3D em Swift

> **Status:** proposta para revisão. Substitui o papel de "plano" do rascunho de especificação (`engine-swift-especificacao.md`), que continua válido como **catálogo de requisitos**. Aqui ficam as **decisões de arquitetura, os desvios propostos em relação ao rascunho, o roteiro de execução e a divisão de trabalho em paralelo**. Nenhum código da engine foi escrito ainda.
> **Idioma:** português; identificadores em inglês.
> **Nome:** "Caju" é o nome do repositório; o rascunho usa o prefixo provisório `Engine`. Sugestão: renomear módulos para `Caju*` (ex.: `CajuCore`) na Fase 0, antes de existir código.

---

## 1. Resumo executivo

1. **O rascunho é bom como catálogo, mas grande demais para ser a v1.** São ~500 requisitos (câmera com rig cinematográfico, texto bidi/CJK, remote content, 3 camadas de UI…). Para uma engine "leve e performática", proponho um **perfil MVP** (§4) com tudo o que sustenta um jogo 3D mobile com UI, e **módulos opcionais** ligados por *package traits* do SwiftPM, para que quem não usa não pague (binário, tempo de build, memória).
2. **Swift idiomático = valores, genéricos e macros, não herança nem existenciais.** ECS com armazenamento por arquétipo, parâmetros de sistema via *parameter packs*, tipos `~Copyable` para recursos únicos, `Span`/`InlineArray`/`UnsafeMutableBufferPointer` nos caminhos quentes, macros (`@Component`, `@Scriptable`, `@View`-helpers) para eliminar boilerplate e gerar reflexão (§3).
3. **Quatro desvios relevantes em relação ao rascunho** (detalhados em §5, cada um com alternativa de volta ao rascunho):
   - **GPU:** RHI próprio, fino e moderno, com backend **Metal primeiro** e **Vulkan depois**, em vez de WebGPU nativo (Dawn/wgpu-native) como padrão. Motivo: tamanho de binário (NFR-007), controle de memória/latência e acesso a recursos de tile/bindless. Shaders compilados **offline**.
   - **UI:** uma camada só de UI visível ao desenvolvedor (a DSL tipo SwiftUI), sobre um **núcleo retido de nós** próprio, com **reatividade de granularidade fina** (Observation) em vez de "reexecutar `body` e fazer diff". Os templates XML saem da v1.
   - **ECS/Agendador:** pool de threads **próprio** (não o pool cooperativo do Swift Concurrency) para o agendador; `async/await` fica nas bordas (I/O, rede, assets).
   - **Texto:** manter HarfBuzz/FreeType, mas **escalonar** os scripts (latim → +cirílico/grego → CJK → RTL) e usar texto de plataforma como *fallback* de IME/edição no começo.
4. **Scripts em runtime:** recomendação de **Luau** (Lua tipado e *sandboxed*, MIT) como linguagem principal, com **WebAssembly** como segunda via (permite escrever scripts em Swift). A engine precisa, desde a Fase 1, de **reflexão de componentes e mensagens** para que isso seja possível depois (§8). Atenção às regras da App Store e ao NFR-030 do rascunho ("nunca baixar código"): ver §8.4.
5. **Paralelização:** depois de uma **Fase 0 curta e sequencial** (esqueleto do pacote, CI, convenções e *contratos* de API), há **8 trilhas independentes** que podem rodar em sessões separadas sem tocar nos mesmos arquivos (§9–10). Os módulos que dependem do ECS e do RHI só entram em ondas posteriores.

---

## 2. Princípios de projeto

| # | Princípio | Consequência prática |
|---|---|---|
| P1 | **Dados primeiro, sem alocação no quadro** | Arenas por quadro, *pools*, nada de `class`/`any`/`Array` crescendo dentro de sistema quente. |
| P2 | **Pague só pelo que usa** | Módulos opcionais por *trait*; sem Foundation completo (usar `FoundationEssentials` onde possível); *dead-stripping* verificado em CI. |
| P3 | **Núcleo puro e testável sem GPU/janela** | Math, ECS, layout, texto (medida), parsers rodam em Linux no CI. |
| P4 | **Contratos antes de implementação** | Cada módulo tem um alvo `*API` ou protocolos estáveis definidos na Fase 0, permitindo trabalho em paralelo. |
| P5 | **Extensão por protocolo/plugin, nunca por *fork*** | Materiais, passes, loaders, backends e *script hosts* são pontos de extensão. |
| P6 | **Medir cedo** | *Benchmarks* (NFR-008, NFR-009, draw calls) entram em CI desde a primeira versão do módulo correspondente. |
| P7 | **Dado externo é hostil** | Parsers com limites e *fuzz* desde o primeiro commit (NFR-020/021). |

---

## 3. Abordagens idiomáticas em Swift

### 3.1 Linguagem e toolchain
- **Swift 6.2+** (ou a estável mais recente na data de início), `StrictConcurrency` ligado (LANG-001). Usar **Swift Testing** nos testes novos.
- **Android:** usar o **Swift SDK para Android** (workgroup oficial) e NDK; Android é alvo de primeira classe desde a Fase 0 (CI compila para `aarch64-linux-android`), porque é onde surgem as surpresas (sem Foundation completo, sem Objective-C, JNI, ciclo de vida da `Activity`).
- **Foundation:** preferir `FoundationEssentials` (menor, portátil). Não usar `NSObject`, KVO, `NotificationCenter` no núcleo.
- **Package traits** (SwiftPM 6.1+) para módulos opcionais: `Text.RTL`, `Net`, `Audio`, `Anim.StateMachine`, `Draco`, `CameraRig`, `Scripting`, `RemoteContent`.
- **Embedded Swift** não é alvo (precisa de ARC/Foundation em partes); mas a regra "sem existenciais e sem reflexão dinâmica no núcleo" mantém a porta aberta.

### 3.2 Recursos da linguagem a usar de propósito
| Recurso | Onde usar | Por quê |
|---|---|---|
| **Parameter packs** (`each T`) | `Query<each D>`, `SystemParam`, tuplas de componentes, `ViewBuilder` | Substitui a lista fixa "tuplas até 12/10" do rascunho (ECS-020, DSL-001) por genéricos sem limite e sem código gerado à mão. |
| **Macros** (`@attached`/`@freestanding`) | `@Component` (registro + reflexão + `requires`), `@Message`, `@Resource`, `@Scriptable`, `#shader`, `@Entry` para `EnvironmentValues` | Menos boilerplate; gera tabelas de reflexão necessárias a scripts, inspector e serialização. |
| **`~Copyable` / `~Escapable`** | `Handle` fortes únicos, tokens de transação do `Commands`, *encoders* de comando da GPU, `Span` de colunas do ECS | Impede cópia acidental/uso após fim do quadro; custo zero. |
| **`Span`/`MutableSpan`/`InlineArray`** | Iteração de colunas, buffers de vértices, matrizes de juntas | Acesso seguro sem *bounds-check* escondido e sem ARC. |
| **Typed throws** | Loaders, parsers, rede (`throws(AssetError)`) | Erros tipados sem *boxing* (NFR-020). |
| **`sending` / `Sendable`** | Fronteira entre laço principal e *job pool*/tarefas | Garante estaticamente a regra "ECS só no laço" (TSK-005). |
| **Observation** (`@Observable`, `withObservationTracking`) | Estado da UI | É da *stdlib*, portátil (Linux/Android), alinhado ao SwiftUI. |
| **Result builders** | DSL de UI e de configuração de `App` | Sintaxe familiar. |
| **Resource/associated-type genéricos com `@inlinable`/`@specialized`** | Caminho quente do ECS | Especialização evita *witness tables*. |

### 3.3 O que evitar no núcleo
`any Protocol` em loops quentes; `class` por entidade/componente; `Dictionary<String,_>` por quadro; `Codable` na carga de assets pesados (usar formatos binários pré-processados); `async/await` no laço principal (RUN-001); *closures* capturando contexto em sistemas (preferir funções livres + parâmetros).

### 3.4 Concorrência: como encaixar o ECS no Swift 6
- O `World` **não é um ator**; é isolado por **disciplina + tipos**: só o laço principal o acessa; trabalho paralelo recebe `UnsafeMutableBufferPointer`/`Span` de colunas via *jobs* tipados (acesso exclusivo garantido pelo grafo de acesso dos sistemas, SCHED-005/ECS-022).
- **Agendador próprio:** pool de threads fixo (núcleos−1), *work-stealing*, fila de *jobs* sem alocação; sistemas sem conflito rodam em paralelo. Swift Concurrency fica restrito a I/O, rede, decodificação e ponte `TaskToWorld` (TSK-003). *Motivo:* o pool cooperativo do Swift não dá controle de afinidade/latência e mistura trabalho de jogo com trabalho de I/O.
- Sistemas `NonSend` e tudo que toca UIKit/Android JNI rodam na **thread principal** (`@MainActor` apenas nessa borda).

### 3.5 Estilo de API do ECS (proposta)
```swift
@Component struct Health { var value: Float }
@Component(requires: Transform.self) struct Enemy { var target: Entity? }

// Sistema = função livre; parâmetros são SystemParams (parameter packs)
func chase(
    time: Res<Time>,
    enemies: Query<(Entity, Mut<Transform>, Enemy), Without<Dead>>,
    players: Query<Transform, With<Player>>,
    mut commands: inout Commands
) { /* ... */ }

App()
  .addPlugins(DefaultPlugins)
  .addSystem(.update, chase.after(input).runIf(inState(.playing)))
  .run()
```
- Validação de conflitos de acesso **na construção do sistema** (ECS-022), usando a informação de tipos dos *packs*.
- `@Component` gera: ID estável do tipo, *layout*, reflexão (nome, campos, tipo de campo), serialização opcional. É o alicerce de scripts, inspector, *prefabs* e `Codable` sob demanda.

---

## 4. Escopo: perfil MVP e módulos opcionais

O rascunho não define fases por escolha. Este plano define **perfis**:

| Perfil | Conteúdo | Meta |
|---|---|---|
| **MVP (v0.x)** | Core/ECS/agendador, Math, Scene, Platform (iOS+Android+macOS), Input (toque + gestos básicos), RHI + Render (PBR simples, unlit, luz direcional, 1 sombra, skinning, instancing), Assets (loader glTF/KTX2, handles, hot reload local), Anim (clipes, player, crossfade, máscaras), UI (DSL + layout + texto latino + widgets básicos), Log/Diag, Testing, Tools (texture, validate-gltf, manifest básico) | "Vertical slice" jogável e medido em aparelho. |
| **v1.0** | + Física de consulta (BVH, raycast, kinematic), áudio, rede, texto completo (RTL/CJK/emoji), acessibilidade nativa, i18n, ToonMaterial, LOD, quirks remotos, remote content | Conformidade com o rascunho (§21 dele) nos itens que sobreviverem à revisão. |
| **Opcional (traits)** | Camera rig/virtual cameras (§7.2 do rascunho), máquina de estados de animação, Draco, `ViewportNode`, UI no mundo avançada, scripting, DoF, projeções oblíquas | Só quando um jogo precisar. |

**Cortes/adiamentos propostos** (justificativa: custo alto, valor concentrado em poucos jogos):
- **Camera rig completo** (RIG-001..100, ~60 requisitos): entra como módulo opcional *depois* do MVP. No MVP, a câmera tem `Camera + Projection + Transform`, `CameraDebug` simples e **dois** comportamentos de fábrica (`Follow`, `Orbit`) sobre o **mesmo** protocolo `CameraBehavior` (RIG-001), de modo que o restante é aditivo.
- **Templates XML (§14.4)** e **compilador Tailwind-like**: removidos da v1 (ver §6.5). O requisito de "tokens/temas" é mantido, mas dentro da DSL.
- **Grid CSS** (UI-002): adiar; stacks + `LazyVGrid` cobrem a maioria.
- **Remote content (§10.3)**: manter na v1.0, mas *depois* de loaders e cache local estáveis.
- **`MeshMerge`/`AtlasMerge`, `forceSoftwareSkinning`, `BlobShadow`**: sob demanda de benchmark.

---

## 5. Arquitetura proposta (módulos e desvios)

### 5.1 Mapa de módulos (mantém a tabela do rascunho com ajustes)

```
Camada 0 (puros, sem dependências):   CajuMath   CajuCore(ECS, agendador, jobs, log)   CajuCollections(arenas, canais)
Camada 1:                             CajuScene  CajuAssetsCore(formatos, loaders puros)  CajuText(shaping/medida)  CajuUILayout(layout puro)  CajuPhysicsSpatial(BVH)
Camada 2 (plataforma/GPU):            CajuPlatform  CajuRHI(+ Metal, + Vulkan)
Camada 3 (integração com ECS):        CajuInput  CajuRender  CajuAssets  CajuAnim  CajuAudio  CajuUI  CajuPhysics
Camada 4:                             CajuNet  CajuTesting  CajuTools(CLI)  CajuScripting(opcional)
```
**Mudança:** os módulos "puros" de domínio (layout de UI, medida/shaping de texto, BVH espacial, parsers de glTF/KTX2) são **separados** das integrações com ECS. Isso (a) permite paralelismo total, (b) deixa testes e *fuzz* em Linux, (c) torna cada peça reutilizável sem a engine.

### 5.2 Desvio A: GPU/RHI (rascunho: WebGPU nativo, RHI-002)
- **Problema do padrão do rascunho:** Dawn/wgpu-native adicionam ~5–15 MB por arquitetura (pressiona NFR-007, 25 MB), uma camada de validação extra por chamada, limites "mínimo universal" (sem *bindless*, sem *tile memory*/*programmable blending* do Metal), e duas dependências C++/Rust grandes no *build* Swift/Android.
- **Proposta:** RHI próprio **fino** (a interface do RHI-001 pode seguir a semântica WebGPU, que é um bom denominador comum, mas com **grafo de quadro (frame graph)** explícito, *bind groups* imutáveis e *arena* de comandos por quadro).
  - **Backend Metal primeiro** (iOS/macOS; é onde dá para desenvolver e depurar rápido), **Vulkan** em seguida (Android).
  - **Shaders:** uma linguagem de autoria compilada **offline** para MSL e SPIR-V (candidatas: **Slang**, ou **WGSL + Naga**), com **reflexão** gerando structs Swift (SHD-002). Sem compilador de shader em tempo de execução → binário menor, sem *stutter* de compilação, `metallib` pré-compilado.
  - **Conformidade:** a mesma suíte de *goldens* (§21.1-2 do rascunho) valida cada backend. Se mais tarde houver interesse em Web, um backend WebGPU entra atrás da mesma interface.
- **Alternativa de volta ao rascunho:** adotar `wgpu-native` já na Fase 2 e medir tamanho/custo; se aceitável, o backend Metal/Vulkan próprio vira otimização futura. **Decisão pedida ao dono do projeto (§12-D1).**

### 5.3 Desvio B: UI (rascunho: 3 camadas + reexecutar `body` com diff)
Ver §6 completo. Resumo: **DSL SwiftUI/Compose-like → núcleo retido de nós → render em lotes**, reatividade fina.

### 5.4 Desvio C: Render com *frame graph* e extração
- `Render World` separado do `Main World` (como em engines modernas): **extração** copia o mínimo para estruturas de render compactas (SoA), permitindo **pipelining** (CPU prepara o quadro N+1 enquanto a GPU desenha o N).
- *Frame graph*: passes declaram leituras/escritas de recursos → alocação transitória, *barriers* e *aliasing* de memória automáticos (importante em mobile com 300 MB, NFR-004).
- **Renderização *forward* (ou forward+ leve)**, com MSAA e *tile-based* friendly (evitar *load/store* desnecessários). Sem G-Buffer no MVP.
- **Instancing e *batching* automáticos** (MESH-005), **LOD** e *culling* por frustum; *occlusion culling* e *culling* na GPU ficam como evolução.
- Texturas **ASTC/KTX2** como caminho padrão; geometria quantizada + **meshopt** (GLTF-001).

### 5.5 Desvio D: Texto
Manter FreeType + HarfBuzz + MSDF (TXT-002/003), mas **escalonar** por script e, enquanto RTL/CJK não estão prontos, usar o texto de plataforma (CoreText / `android.text`) **só para IME, preedit e medição de *fallback*** (o desenho continua no atlas da engine). O "requisito de conformidade v1.0" para árabe/hebraico/CJK permanece, mas como **marco da v1.0**, não do MVP.

### 5.6 Outras decisões do rascunho que mantenho
Sistema de unidades/coordenadas (§0.3), `Handle` fraco/forte com descarga em 1 quadro, `AssetSource` em camadas (SRC), `Transform`/`GlobalTransform` com propagação suja, observadores/mensagens com vida de 2 ciclos, fixed timestep com teto de passos, quirks de GPU como **dados**, `TestApp` sem janela/GPU, ferramentas offline determinísticas.

### 5.7 Pontos do rascunho que merecem correção/esclarecimento
- **§1.2 vs §8 (scripting):** o rascunho exclui scripting e proíbe código baixado (NFR-030). Se scripts forem desejados (e foram pedidos), esse requisito precisa ser reescrito (§8.4).
- **LANG-002** lista dependências permitidas; precisa incluir o compilador de shader (apenas ferramenta), `meshoptimizer`, e o *runtime* de scripts quando houver.
- **Apêndice A** é rastreio de um cliente Bevy específico; útil como checklist de paridade, mas não como arquitetura. Recomendo mover para `docs/apendices/`.
- **PERF-pre-aquecimento** (NFR-005) referencia um ID inexistente; trocar por SHD-003/SHD-004.
- **MATH-008** ("não alocar") deve ser reformulado como "tipos de valor, sem ARC".

---

## 6. UI declarativa familiar a quem faz mobile

### 6.1 Objetivo
Um dev SwiftUI (ou Compose/Flutter) deve **reconhecer a sintaxe em 5 minutos** e ser produtivo no mesmo dia. Mas o resultado deve ser **leve** (sem a complexidade do `AttributeGraph` do SwiftUI) e rodar em Android.

### 6.2 Como seria o código (proposta)
```swift
struct ShopItemRow: View {
    @Environment(\.theme) var theme
    let item: Item
    @State private var pressed = false

    var body: some View {
        HStack(spacing: theme.space.md) {
            Image(item.icon).frame(width: 48, height: 48).cornerRadius(8)
            VStack(alignment: .leading) {
                Text(item.name).font(.headline)
                Text("\(item.price) coins").foregroundColor(theme.color.secondary)
            }
            Spacer()
            Button("Comprar") { store.buy(item) }.buttonStyle(.primary)
        }
        .padding(theme.space.md)
        .background(theme.color.surface, in: RoundedRectangle(cornerRadius: 12))
        .scaleEffect(pressed ? 0.97 : 1)
        .animation(.spring, value: pressed)
        .onTap { /* ... */ }
    }
}
```
- Mesma ergonomia: `View`, `@State`, `@Binding`, `@Environment`, `@Observable`, modificadores encadeados, `ForEach`, `LazyVStack`, `NavigationStack`, `.sheet`, `.task`.
- Para quem vem de **Compose/Kotlin**: o mesmo conjunto de modificadores serve; documentação com tabela de equivalência (`Column`≈`VStack`, `Modifier.padding`≈`.padding`, `remember`≈`@State`, `LaunchedEffect`≈`.task`).
- **Não** copiar os nomes quando isso gerar confusão ou risco de marca: usar nomes próprios onde a semântica difere (ex.: `Image` de engine vs `Image` do SwiftUI → módulo com namespace `Caju.Image`).

### 6.3 Arquitetura em camadas
```
 DSL (View, builders, modificadores, @State/@Environment)           <- API pública principal
        │  "reconciliação" na criação/estrutura, reatividade fina no estado
        ▼
 UI Tree retido (CajuUICore): nós compactos, estilo, ComputedNode    <- sem ECS por nó (ver 6.4)
        │  layout puro (CajuUILayout), a11y tree, hit-testing
        ▼
 Display list / Batcher  ->  RHI (SDF para retângulos, texto MSDF)  <- ≤ 40 draw calls (UIR-001)
```

### 6.4 Desvio: reatividade de granularidade fina e núcleo retido
- **Rascunho:** `body` reexecuta e há *diff* de entidades (DSL-005/006), com UI feita de entidades do ECS.
- **Proposta:** estilo **Solid/Compose**:
  1. `body` roda **uma vez por instância de view** e constrói/atualiza a subárvore.
  2. Leituras de `@State`/`@Observable` dentro de **propriedades de modificadores** e de `Text` ficam registradas como **dependências** (Observation tracking). Quando o dado muda, só a **propriedade do nó** é atualizada (sem reexecutar `body`), e só **estrutura condicional** (`if`, `ForEach`) reconstrói pedaços.
  3. Custo proporcional ao que mudou (DSL-005 atendido por construção) e **zero trabalho** em quadro sem mudança (UIR-004).
- **Núcleo retido próprio em vez de uma entidade ECS por nó:** layout quer memória contígua por árvore, ordem filho-pai estável e baixo *overhead* por nó. Integração com o ECS ocorre **nas bordas**: `WorldAnchor`, eventos de ponteiro (mensagens), `Environment` alimentado por recursos, e `HostedEntity` para embutir objetos do mundo. (Se o dono preferir manter UI 100 % ECS, o custo é memória por nó e perda de contiguidade: §12-D2.)
- **Layout:** implementar o protocolo de layout **estilo SwiftUI** (proposta de tamanho → medida → posicionamento: `sizeThatFits`/`placeSubviews`) como base de `VStack/HStack/ZStack/Grid`, `frame`, `layoutPriority`, `Spacer`, `fixedSize`. Isso é o que o dev mobile espera, e é mais simples que um flexbox CSS completo. Flex/Grid CSS-like vira modo opcional (adiado). Resultado em pixels físicos, no mesmo ciclo (UI-004).
- **Hot reload:** Swift não recarrega código em dispositivo; para iteração rápida, o caminho é **(a) *previews* offscreen em macOS** (DSL-011, `ViewPreview`) e **(b) UI como dado**: a mesma árvore da DSL serializável (JSON/binário), editável e recarregável, que também serve para **UI controlada por script** e **UI remota** (§8). Isso substitui o XML do rascunho.

### 6.5 Camadas de UI no plano
| Item do rascunho | Decisão |
|---|---|
| UI Core (nós, estilo) | Mantida, como `CajuUICore` interno. |
| Templates XML + Tailwind compile | **Removidos da v1**; substituídos por "UI como dado" (árvore serializada da DSL). |
| DSL SwiftUI-like | **API principal**; reatividade fina. |
| Widgets (WID) | Biblioteca `CajuUIKit` em cima da DSL (Button, TextField, Toggle, Slider, ScrollView, List, Sheet, Toast…), com tokens/temas e estados. |
| A11y (A11Y) | Árvore de acessibilidade derivada do nó **desde o início** (campo `role/label` no nó), espelhada à plataforma em marco posterior. |
| Animação de UI (UIA) | `withAnimation`/`.animation(_, value:)`, molas, *transitions*; propriedades de **desenho** (opacidade/transform/cor) nunca causam *relayout* (UIA-004). |
| UI no mundo (WLD) | `WorldAnchor` no MVP; `ViewportNode` e oclusão depois. |

### 6.6 Renderização de UI leve
SDF no shader para cantos/borda/sombra (UIR-002); um **vertex buffer dinâmico único** por quadro, *batching* por material/recorte; cache de display list por subárvore estável; sem trabalho de UI em quadro parado (também habilita `UpdateMode.reactive`, PWR-001).

---

## 7. Leveza e performance: propostas concretas

**Memória e CPU**
- **Arquétipos em colunas (SoA)** com *chunks* de tamanho de linha de cache; *change ticks* por coluna; consultas iteram `Span`s.
- **Alocadores por quadro** (arena) para `Commands`, extração de render, listas de visíveis, geometria de UI.
- **Entidades como `UInt64` (índice+geração)**; *handles* de asset também numéricos, com *slab*; sem `class` por asset.
- **Transform:** propagação paralela por subárvore suja; `GlobalTransform` em SoA.
- **Animação:** amostragem em SIMD, *rate scaling* (ANM-015), cull fora da tela (ANM-016); *skinning* na GPU, matrizes em buffer por instância.
- **Orçamentos**: `UploadBudget` (IMG-005), `BudgetedQuery` para oclusão/raycasts por quadro, `PerformanceGovernor` (DIAG-002).

**GPU e energia**
- ASTC por padrão; `Memoryless` para MSAA/depth no Metal; evitar *load* de attachments; passes agrupados em *render pass* único quando possível.
- Pipelines **pré-compiladas** (cache de PSO persistido por dispositivo) e pré-aquecidas por cena (SHD-003/004).
- Modo **reativo** (PWR-001): sem mudanças → sem *submit*.

**Binário e build**
- Núcleo sem Foundation pesado; traits para módulos opcionais; *dead stripping* + `-Osize` em módulos não quentes; medir tamanho no CI e falhar acima do teto (NFR-007).
- Evitar *generics* sem especialização em *public API* quente (usar `@inlinable`/`@_specialize`), mas vigiar o tempo de compilação (parameter packs + macros podem pesar; medir no CI).

**Medição desde o dia 1**
- *Benchmarks* automatizados: ECS (NFR-008), layout (NFR-009), draw calls, tempo de quadro p50/p95 em aparelho de referência; relatório JSON versionado; regressão >10 % bloqueia merge.

---

## 8. Scripts em tempo de execução (futuro)

### 8.1 O que a engine precisa agora (para não fechar a porta)
1. **Reflexão estática de componentes, recursos, mensagens e eventos** gerada por `@Component`/`@Message`/`@Resource` (nome, campos, tipos, ID estável).
2. **API de mundo "por ID de tipo" além da genérica**: `world.get(entity, componentID)`, `query(dynamic:)`, `spawn(dynamic:)`, `send(messageID, payload)`. Necessária para qualquer linguagem não-Swift.
3. **Sistemas dinâmicos**: o agendador aceita sistemas cujo acesso (leitura/escrita) é declarado por dados, e não só por tipos genéricos. Mesma validação de conflito.
4. **Formato de serialização de entidades/cenas** (*prefabs*) e **UI como dado** (§6.4).
5. **Limites de segurança**: orçamento de instruções/tempo por quadro, memória máxima, API *allow-list*.

### 8.2 Candidatas (comparação)
| Opção | Prós | Contras | Veredito |
|---|---|---|---|
| **Luau** (Lua tipado, Roblox, MIT) | Pensado para código **não confiável** (*sandbox* nativo), tipagem gradual, interpretador rápido, *coroutines*, pequeno (~centenas de KB), C API estável, muito usado em jogos | Código em C++ (precisa de *target* C++ no SwiftPM e *interop*); sem JIT em iOS (interpretador já é bom) | **Recomendada (principal).** |
| **Lua 5.4** (PUC) | Mínimo, C puro, fácil de integrar | Sem tipagem, *sandbox* manual | Alternativa se C++ for problema. |
| **JavaScript** (JavaScriptCore no iOS; QuickJS no Android) | Ecossistema, familiaridade | Dois motores diferentes (semântica/performance), JSC não existe em Android; QuickJS é maior e mais lento | Só se houver forte demanda web. |
| **WebAssembly** (wasm3/WAMR em modo interpretador) | **Poliglota**; dá para **escrever scripts em Swift** (SwiftWasm), Rust, C; *sandbox* excelente, determinístico | Interpretador 10–30× mais lento que nativo; *toolchain* pesada para o autor; AOT/JIT inviáveis em iOS | **Segunda via**, para lógica mais pesada/portável e para quem quer Swift. |
| **Swift como script** (dylib carregada) | Mesma linguagem | **Inviável em iOS** (sem carga de código novo), sem *sandbox*; só serve em desenvolvimento no macOS | Somente *hot reload* de desenvolvimento (macOS). |
| **Lógica em dados** (grafos/estados/regras JSON) | Seguro, sem runtime | Limitado | Complemento (máquina de estados, UI como dado). |

### 8.3 Arquitetura proposta
```
CajuScripting (trait)
 ├─ ScriptRuntime (protocolo): load(module, bytes), call, tick, memória/tempo limite
 ├─ LuauRuntime  (principal)
 ├─ WasmRuntime  (futuro)
 ├─ Bindings: gerados a partir da reflexão (@Scriptable / registro automático de componentes)
 └─ ScriptSystem: roda scripts em um conjunto de sistemas (Update/FixedUpdate) com orçamento
```
- Scripts veem uma **API restrita** (entidades, componentes registrados como *scriptable*, mensagens, timers, UI como dado, `Task`-like via *coroutines*). Nada de acesso direto a GPU, arquivos ou rede.
- **Hot reload** de scripts em desenvolvimento (e em produção, ver §8.4).
- **Ferramentas:** `caju-tool script-check` (tipagem Luau, *lint*), empacotamento no manifest como **dado assinado**.

### 8.4 Segurança e políticas de loja (atenção)
- O rascunho proíbe **baixar código** (NFR-030/REM-007). Scripts **embarcados no app** são código do app e não violam isso; **scripts baixados** exigem mudar o requisito: *assinatura* (chave embutida), *sandbox*, orçamento e *allow-list* de API.
- **Apple App Store:** as diretrizes (2.5.2) restringem download de código executável, com exceções para interpretadores embutidos cujo código não altere o propósito principal do app. **Verifique o texto vigente com o time jurídico/*App Review* antes de entregar scripts remotos no iOS.** Embarcar scripts no bundle é o caminho seguro.
- **Decisão pedida (§12-D4):** apenas scripts embarcados na v1 do scripting, ou também remotos assinados?

### 8.5 Roteiro de scripting (pós-MVP)
S1 reflexão e API dinâmica no ECS (**já na Fase 1**) → S2 `ScriptRuntime` + Luau + bindings básicos → S3 UI como dado + eventos → S4 *hot reload* e `script-check` → S5 WASM (opcional) → S6 scripts remotos assinados (se decidido).

---

## 9. Plano de execução: fases e dependências

> **Convenção:** "Trilha" = unidade de trabalho de **uma sessão**, com diretório próprio, contrato (protocolos/tipos públicos) e critérios de pronto. Sem datas (o rascunho evita estimativas); tamanho relativo: P/M/G.

### Fase 0: Fundação (sequencial, 1 sessão, P)
Obrigatória antes do paralelismo. Entregas:
1. **`Package.swift` com TODOS os targets** de §5.1 já declarados (com um arquivo-stub em cada), traits, plataformas, flags (`StrictConcurrency`, `-warnings-as-errors`). **Depois disso, só uma sessão por vez altera `Package.swift`** (ver §10.3).
2. **CI**: build+teste em Linux e macOS; *build* de verificação para iOS e Android; grafo de dependências (MOD-001 como teste); medição de tamanho.
3. **Convenções**: `CONTRIBUTING.md`, estilo (swift-format), nomes, política de erros (typed throws), `CODEOWNERS` por diretório, template de PR, ADRs (`docs/adr/`).
4. **ADRs iniciais** decidindo §12 (D1–D5).
5. **Contratos de API** (`*API` ou arquivos `Contracts/`): protocolos e tipos públicos mínimos de `Core` (esboço do `App`, `Plugin`, `Component`, `Resource`, `Message`), `RHI` (`RenderDevice`, `CommandEncoder`, descritores), `AssetLoader`, `ScriptRuntime` (vazio), `TextShaper`, `UILayout` (nó de entrada/saída), `SpatialIndex`. Servem de **fronteira** para trilhas paralelas.
6. **Harness de benchmark** e de *fuzz*.
7. Renomear prefixos (`Caju*`).

### Onda 1: paralelo total (sem depender de ECS nem de GPU)
Pode começar **assim que a Fase 0 fechar**. Trilhas independentes (8 sessões simultâneas possíveis):

| Trilha | Módulo(s) | Entrada (contrato) | Entrega | Tamanho |
|---|---|---|---|---|
| **T1 Math** | `CajuMath` | nada | Tipos SIMD, interseções, cor, easing, testes de propriedade | M |
| **T2 Core/ECS** | `CajuCore`, `CajuCollections` | Contratos Fase 0 | World, arquétipos, Query/packs, Commands, agendador+jobs, mensagens, observadores, estados, tempo, log, reflexão (`@Component`) | **G (caminho crítico)** |
| **T3 RHI + Metal** | `CajuRHI`, backend Metal | Math (só tipos básicos, copiados da Fase 0 até T1 fechar) | Interface do RHI, Metal: buffers/texturas/pipelines/passes, *frame graph* básico, compilação offline de shaders, app de exemplo (triângulo→cubo) | G |
| **T4 Assets puros** | `CajuAssetsCore` | Contrato `AssetLoader` | Parsers glTF (validação rigorosa GLTF-006), KTX2/Basis, WAV/Opus decode *wrappers*, PNG/JPEG via libs; **sem** ECS; *fuzz* | G |
| **T5 UI Layout + DSL base** | `CajuUILayout`, parte de `CajuUICore` | Contrato `UILayout` | Árvore retida, protocolo de layout SwiftUI-like, Stacks/ZStack/frame/Spacer, hit-testing, a11y tree; testes sem GPU | G |
| **T6 Texto puro** | `CajuText` | Contrato `TextShaper` | FreeType/HarfBuzz, medida (TXT-004), quebra de linha, atlas MSDF (sem GPU), `TextEditor` (modelo) | G |
| **T7 Espacial/Física base** | `CajuPhysicsSpatial` | Math | BVH dinâmica, raycast/shapecast/sobreposição (PHY-010..022) sobre estruturas puras | M |
| **T8 Net + Plataforma nativa** | `CajuNet`, `CajuPlatform` (host iOS/Android/macOS) | Contrato de eventos de janela/entrada | `HTTPClient`/WebSocket; host iOS (UIScene, `CAMetalLayer`), Android (Activity/Surface, JNI), eventos brutos, safe area, IME *plumbing* | G |
| **T9 Tools base** (opcional na Onda 1) | `CajuTools` | T4 parcial | CLI esqueleto, `validate-gltf`, `texture`, saída determinística | M |

> T1 é pequena e **bloqueia levemente** T3/T7; na Fase 0, publicar os tipos mínimos de `Vec/Mat/Quat` (ou fazer T1 primeiro, é rápido).

### Onda 2: integração com ECS e render (depende de T2 + T3, parcial de T1/T4/T8)
Aqui já há **dependências entre módulos**; sessões diferentes ainda podem trabalhar em paralelo **por módulo**, desde que os contratos estejam fechados.

| Trilha | Módulo | Depende de | Observação |
|---|---|---|---|
| **T10 Scene** | `CajuScene` | T1, T2 | Transform/hierarquia/visibilidade; **necessário** para quase tudo da Onda 2. Fazer primeiro (P/M). |
| **T11 Assets+ECS** | `CajuAssets` | T2, T4 | `AssetServer`, `Handle`, `Assets<T>`, eventos, carga assíncrona, hot reload, `AssetSource` em camadas |
| **T12 Render** | `CajuRender` | T3, T10, T11 | Extração, câmeras, malhas, materiais padrão, luzes/sombra, instancing, culling, skinning; `NullRenderer` |
| **T13 Input** | `CajuInput` | T8, T10 | Estado, toques, gestos, `PointerCapture`, picking base |
| **T14 UI integrada** | `CajuUI`/`CajuUIKit` | T5, T6, T2 (+ T3 para desenhar) | DSL completa, reatividade, widgets, batcher; integração de texto na GPU |
| **T15 Anim** | `CajuAnim` | T2, T10, T11 (glTF clipes) | Clipes, grafo, player, transições, máscaras, skinning por nomes |
| **T16 Physics ECS** | `CajuPhysics` | T7, T2, T10 | Componentes, sincronia de transformações, eventos de colisão, `KinematicCharacter` |
| **T17 Audio** | `CajuAudio` | T2, T11, T8 | Mixer, barramentos, streaming |
| **T18 Testing** | `CajuTesting` | T2 (e T12 p/ golden) | `TestApp` cedo (junto com T2); `NullRenderer`/golden com T12 |

### Onda 3: marco "vertical slice" (integração, sequencial/curta)
Uma sessão de integração monta um **jogo-demo** (personagem animado com skinning, UI de loja, câmera, toque), roda em iPhone e Android, mede NFR-001/002/003/008/009 e produz o **relatório de benchmark**. Defeitos voltam às trilhas donas.

### Onda 4: completude v1.0 (paralelo por módulo)
Texto completo (RTL/CJK/emoji), IME nativo bidirecional, acessibilidade espelhada, i18n, ToonMaterial, LOD, quirks remotos + Vulkan (se ainda não), remote content + manifest + `publish`, governador de energia, ferramentas restantes (lod, atlas, skeleton-check, animation), `ViewportNode`, UI no mundo.

### Onda 5: opcionais e scripting
Camera rig (+ virtual cameras), Luau, WASM, máquina de estados de animação, Draco, projeções avançadas, física dinâmica (extensão).

### Caminho crítico
`Fase 0 → T2 (ECS/agendador) → T10 (Scene) → T12 (Render) → T14 (UI integrada) → Vertical slice`. Em paralelo, T3 (RHI) precisa estar pronto antes de T12; T5/T6 devem estar prontos antes de T14.

### Grafo de dependências (resumo)
```
Fase0 ─┬─ T1 Math ────────────┬──────────────► T7 Spatial ─► T16 Physics
       ├─ T2 Core/ECS ──┬─────┼─► T10 Scene ─┬─► T12 Render ─► T14 UI ─► Slice
       │                │     │              ├─► T13 Input
       │                │     │              └─► T15 Anim
       ├─ T3 RHI/Metal ─┼─────┴─────────────────► T12
       ├─ T4 Assets puros ───────► T11 Assets+ECS ─► T12, T15, T17
       ├─ T5 UI Layout ──────────────────────────► T14
       ├─ T6 Texto puro ─────────────────────────► T14
       └─ T8 Net/Plataforma ─────────────────────► T13, T17
```

---

## 10. Como paralelizar sem conflitos

### 10.1 Regras de ouro
1. **Uma trilha = um diretório = um dono por vez.** Cada módulo vive em `Sources/<Módulo>/` e `Tests/<Módulo>Tests/`; uma sessão não edita o diretório de outra.
2. **Contrato antes de código:** mudança em API pública que cruza módulos exige **PR de contrato** próprio (pequeno, rápido de revisar), mergeado **antes** do trabalho que o usa.
3. **`Package.swift` é trancado:** todos os targets já existem desde a Fase 0. Novas dependências entre targets ou de pacotes externos passam por **PR dedicado** e curto; sessões não os incluem no PR de feature.
4. **Sem arquivos compartilhados "genéricos"** (`Utils.swift`, `Extensions.swift`). Cada trilha tem seu namespace.
5. **Um PR por trilha por vez**, pequeno, com `CODEOWNERS` definindo revisão; *rebase* frequente em `main`.
6. **Gerados em diretório próprio** (`Generated/`) e determinísticos, para não gerar conflito de merge.
7. **Recursos compartilhados sensíveis** (CI, docs de arquitetura, ADRs): somente a sessão coordenadora (ou o dono) altera; as trilhas propõem em PR separado.

### 10.2 O que pode andar em paralelo desde a Onda 1
Math, Core/ECS, RHI+Metal, Assets puros (parsers), UI Layout, Texto, Espacial, Net+Plataforma, Tools. São **mutuamente independentes** porque dependem apenas de contratos/tipos da Fase 0 e usam *mocks*/dublês até o módulo real chegar.

### 10.3 Matriz de conflito (quem toca quê)
| Área | Dono único | Outras trilhas podem… |
|---|---|---|
| `Package.swift`, CI, `CODEOWNERS` | Coordenação/Fase 0 | propor via PR separado |
| `Sources/CajuCore` | T2 | só ler; pedir mudança via contrato |
| `Sources/CajuRHI*` | T3 | consumir protocolo |
| `Sources/CajuAssetsCore` | T4 | idem |
| `Sources/CajuUILayout`/`CajuUICore` | T5 | idem |
| `Sources/CajuText` | T6 | idem |
| `Sources/CajuPlatform`, `CajuNet` | T8 | idem |
| `docs/adr` | Coordenação | comentar |
| Shaders (`Resources/Shaders`) | T3 até a Onda 2; depois T12 | — |

### 10.4 O que **não** deve começar antes de a fundação existir
- **Render integrado (T12)**: precisa de ECS (T2), Scene (T10), RHI (T3) e Assets (T11) estáveis.
- **UI integrada (T14)**: precisa de T5, T6 e de um RHI utilizável.
- **Animação (T15)** e **Input (T13)**: precisam de Scene e Assets/Plataforma.
- **Scripting**: só depois de **reflexão e API dinâmica** do ECS (§8.1) estarem estáveis.
- **Camera rig e features opcionais**: só após o vertical slice.
- **Qualquer ajuste fino de performance**: só com *benchmark* existente.

### 10.5 Sessão coordenadora
Uma sessão (ou o dono) mantém: backlog, ADRs, revisão de contratos, ordem de merge, e o *dashboard* de benchmark. Evita deadlock quando duas trilhas precisam do mesmo contrato.

### 10.6 Estratégia de branches/worktrees
`main` protegida; uma branch por trilha (`track/t2-core`), curta e rebaseada; *feature flags*/traits para código ainda não integrado; CI roda apenas o que a trilha toca + testes de grafo/ABI para todos.

---

## 11. Marcos e critérios de pronto

| Marco | Critério |
|---|---|
| **M0** Fundação | Pacote compila em macOS/Linux; iOS e Android compilam; CI verde; ADRs D1–D5 decididos. |
| **M1** Núcleos puros | T1, T2, T4, T5, T6, T7 com testes (e *fuzz* nos parsers); benchmarks ECS/layout dentro da meta. |
| **M2** Triângulo→cubo em aparelho | T3 + T8: janela iOS e Android, cubo texturizado em Metal (Vulkan quando disponível). |
| **M3** Cena glTF com skinning e UI | T10–T15 integrados em demo. |
| **M4** Vertical slice medido | NFR-001/002/003/008/009 medidos; relatório JSON em CI. |
| **M5** v1.0 | Itens `DEVE` priorizados do rascunho com teste; acessibilidade/i18n/texto completo. |
| **M6** Scripting | Luau embarcado com bindings reflexivos; *hot reload* dev. |

**Critério geral de pronto por trilha:** testes passando em Linux/macOS (quando aplicável), sem avisos de concorrência, API documentada (DocC), *benchmark* quando existe meta, *fuzz* quando existe parser, sem `!`/`try!`/`fatalError` em caminho com dado externo.

---

## 12. Decisões pedidas ao dono do projeto

| ID | Decisão | Recomendação |
|---|---|---|
| **D1** | Backend de GPU: RHI próprio (Metal→Vulkan) **ou** WebGPU nativo (Dawn/wgpu-native) como no rascunho? | **RHI próprio**, mas validar o tamanho de `wgpu-native` com um protótipo de meio dia antes de fechar. |
| **D2** | UI como entidades do ECS **ou** núcleo retido próprio com bordas no ECS? | **Núcleo retido** (§6.4). |
| **D3** | Reatividade: *diff* após reexecutar `body` (rascunho) **ou** granularidade fina via Observation? | **Granularidade fina.** |
| **D4** | Scripts: só embarcados **ou** também remotos assinados? E linguagem? | **Luau embarcado primeiro**; remotos só após análise de política de loja. |
| **D5** | Renomear prefixo `Engine` → `Caju`? | Sim, antes de existir código. |
| **D6** | Ferramenta de shader: **Slang** ou **WGSL + Naga**? | Decidir em protótipo na T3 (qualidade de reflexão e suporte a MSL/SPIR-V). |
| **D7** | Aparelhos de referência (alto/médio) para os NFRs | Definir na Fase 0 (ex.: um iPhone e um Android 2022). |
| **D8** | Nível mínimo do SO: iOS 17 / Android API 29 (rascunho) | Manter; reavaliar se atrapalhar APIs de Swift modernas. |

---

## 13. Riscos principais

| Risco | Mitigação |
|---|---|
| **Swift no Android** ainda tem arestas (SDK, Foundation, depuração) | CI Android desde a Fase 0; evitar APIs só-Apple; spike cedo em T8. |
| **Tempo de compilação** com parameter packs/macros/genéricos | Medir no CI; fronteiras de módulo; `@inlinable` seletivo. |
| **Escopo do rascunho** | Perfil MVP; módulos opcionais; revisão trimestral do que foi cortado. |
| **ECS + concorrência estrita** é a parte mais difícil de acertar | T2 como caminho crítico, com *prova de conceito* antes de congelar a API; testes TSan. |
| **Dependências C/C++** (HarfBuzz, FreeType, KTX/Basis, Luau, meshopt) | Encapsular em targets C/C++ do SwiftPM, versões fixas, CI nos três SOs. |
| **Texto internacional** (bidi/CJK/IME) é um poço sem fundo | Escalonar por script; usar plataforma no IME inicialmente. |
| **Políticas de loja** para scripts remotos | Decidir D4; começar com embarcados. |
| **Perda de dispositivo/superfície** no mobile | Testes forçados desde M2; recursos reconstruíveis a partir de dados da CPU. |

---

## 14. Primeiros passos concretos (próxima sessão)

1. Abrir sessão **Fase 0** (escopo §9) e produzir M0; decisões D1–D8 viram ADRs.
2. Lançar em seguida, em paralelo: **T2 (Core/ECS)**, **T1 (Math)**, **T3 (RHI/Metal + spike de shader)**, **T4 (glTF/KTX2 parsers)**, **T5 (UI layout)**, **T6 (Texto)**, **T8 (Plataforma/Net)**; T7 e T9 quando houver capacidade.
3. Cada sessão recebe: o trecho do rascunho que cobre seus requisitos (IDs), o contrato da Fase 0, o diretório que possui e os critérios de pronto de §11.

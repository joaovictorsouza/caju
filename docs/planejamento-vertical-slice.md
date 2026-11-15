# Plano do vertical slice (M4)

> **Status:** proposta para revisão do dono (2026-11-15). Não implementa nada e não toca `Package.swift` nem CI. Base: [planejamento-engine.md](planejamento-engine.md) (§8 e marcos M3/M4), [briefs/onda-1.md](briefs/onda-1.md), ADR 0005 (Foundation só nas bordas) e ADR 0007 (aparelhos). Números marcados `(?)` não foram medidos.

## 0. Objetivo e interpretação
O dono pediu para usar `resortclient` (Rust + Bevy 0.19 + Avian 0.7, Resort Game) e `toon-characters-bevy` (protótipo Bevy 0.20 de personagem toon modular) como **referência e fonte de assets** do vertical slice da engine, **sem servidor** (tudo local). Interpretação adotada: este documento **planeja e prepara um slice incremental**, que será portado fatia a fatia conforme as trilhas da Onda 1 fecham. Nada é portado agora.

O slice, como definido no plano, é: **personagem animado com skinning, UI de loja, câmera e toque**, medido em iPhone 16 Pro e Galaxy S22+. O jogo de referência dá a *cena concreta*: uma sala em grade (estilo Habbo), um avatar que anda até o tile tocado, uma loja com saldo e compra.

## 1. O que os jogos de referência têm

### 1.1 `resortclient` (cliente do Resort Game)
Rust, Cargo workspace (`protocol`, `nakama_client`, `game`, `toon_avatar`, `animals`). ~31 mil linhas de Rust. Servidor autoritativo (Nakama, repositório `resort-game-server`); o cliente só desenha e envia intenções.

| Área | O que existe | Fonte |
|---|---|---|
| **Sala** | Grade de tiles `1,0 × 0,2 × 1,0 m` a partir de um *heightmap* de strings (`'x'` = sem piso), porta, salas irregulares (octógono, L). Paredes **só nos dois lados do fundo** (vista em corte); parede entre câmera e avatar fica translúcida (alpha 0,22). Altura 2 tiles, espessura 0,16, postes nos cantos | `room.rs`, spec 0013 |
| **Câmera** | Perspectiva FOV 45°, 45° de elevação e 45° de giro fixos, **segue o avatar** com suavização exponencial independente de FPS, presa aos limites da sala. Zoom 4 tiles até enquadrar a sala (≥ 12); *pinch* (toque) e roda do mouse | `camera.rs`, spec 0013 |
| **Toque/clique** | Raio da câmera contra o plano `Y = 0,1` → `(floor x, floor z)`. No toque o comando dispara **ao soltar** e só se o dedo andou < 12 px e nunca houve dois dedos (pinch/arrasto não movem o avatar). Cliente envia `MOVE_REQUEST`; **servidor devolve o caminho** (`AVATAR_PATH`) e o cliente interpola | `input.rs`, ADR 0004 |
| **Avatar** | Personagem toon modular (ver §1.2), `idle`/`walk`/`sit`/`lay`, expressões e objeto na mão (copo/lata); LOD e *tier* por aparelho | `toon_avatar`, ADR 0010/0015, spec 0006 |
| **Móveis e construção** | Catálogo `furniture-catalog.json` (v1): nome, categoria, `width × depth`, `walkable`, cor, `asset_id` (vazio na maioria). **Sem GLB de móvel no repositório**: renderiza *cuboides* paramétricos coloridos. Modo construção com *ghost* verde/vermelho translúcido, snapping, giro de 90°, recolher | ADR 0006, `furniture.rs` (1 373 linhas) |
| **Pets** | Cachorro shih-tzu: skinned, toon, LOD, rota e ações (`idle/sit/lay/walk/run/bark/pant`) | crate `animals`, `pet.rs` |
| **Loja e HUD** | Chips de saldo (prata/ouro), botão Loja, janela de duas colunas: menu lateral de categorias/subcategorias (só o ramo selecionado expande) + grade de ofertas com miniatura, nome e preço (só prata, só ouro, ouro+prata); **busca** sem acento/maiúscula em todas as categorias; botão cinza sem saldo; compra de 1 unidade atualiza saldo e inventário; som ao ganhar ouro | spec 0008, `shop.rs` (1 003 linhas, lógica pura testada) |
| **Telas fora do slice** | Login/social, apelido, navegador de salas, criador de personagem (1 355 linhas), inventário, menu do avatar, status/conexão, IME, área segura. Várias migraram para **Compose** no host KMP (ADR 0017) | `ai-docs/specs`, `kmp/` |
| **UI (técnica)** | HTML + Tailwind gerado (`tools/ui`) lido pelo `bevy_hui`; 41 ícones Phosphor em PNG; fonte Inter (OFL) | `assets/ui`, ADR 0009 |
| **Áudio** | Um único som (`gold_received.wav`, gerado por script, vai para a CDN). Sem música | spec 0008 |
| **Rede/contrato** | Protocolo 3.1; fixtures JSON em `contract/fixtures` (`room_snapshot`, `shop_catalog`, `wallet`, `avatar_appearance`, `avatar_posture_changed`, `pet_*`…) e `furniture-catalog.json` | `contract/` |
| **Assets pesados** | **Não estão no repositório**: vivem no repositório privado `resort-game-assets` e chegam por CDN (ADR 0011, 0015). No clone só há fonte Inter, UI HTML e ícones | `assets/` |

### 1.2 `toon-characters-bevy` (protótipo de personagem)
~2,1 mil linhas de Rust (`lib`, `toon`, `atlas`, `merge`, `quality`, `attach`, `ui`) + shaders WESL + ferramentas Python/Blender/Rust (`tools/`). É a origem da crate `toon_avatar` do `resortclient`. Verificado nos arquivos:

| Item | Valor medido |
|---|---|
| Esqueleto | **71 joints** (`CC_Base`), idêntico em corpo, cabeça e roupas; roupa é re-ligada ao esqueleto do corpo **por nome de joint** |
| Corpos | 2 (`F`, `M`), 4 rostos cada, 31 cabelos, 11 chapéus, 14/13 tops, 6 bottoms, 7 sapatos, 4 conjuntos, 2 óculos (`avatar_catalog.json`); 68 materiais (`materials.json`) |
| Malhas | GLB com `POSITION/NORMAL/TEXCOORD_0/JOINTS_0/WEIGHTS_0` **e `COLOR_0..3`**; 3 LODs: original (corpo ≈ 5 986 tris; cabeça ≈ 5 252 tris), `lod1`, `lod2` (corpo ≈ 2 088 tris). Cabeça `lod2` pesa ≈ 145 KB contra 2,7 MB no original |
| Morph targets | **33 blend shapes** na cabeça original (expressões `happy/angry/sad/surprised`, olhos, piscar, mandíbula, `eye_size`, `nose_length`); o `lod2` não os tem |
| Materiais | `KHR_materials_specular` apenas; **sem imagens embutidas** (texturas externas) |
| **Texturas** | Não são albedo: são **mapas de máscara RGB** (`*_RGBMap`) e *normal maps*. A cor final vem do shader toon (3 regiões R/G/B, cada uma um gradiente entre duas cores, + rampa de luz `ColorRamp.png`, contorno falso e *rim light*; ver `shaders/toon.wesl`, 122 linhas, e `toon_atlas.wesl`, 131). Sem esse shader o personagem não tem cor |
| Formatos de textura | PNG (90 MB) e **`.basis` UASTC** (BasisLZ v13, *não* KTX2): 512 px = 24 MB, 1024 px = 83 MB, 2048 px = 223 MB; atlas de pele+rosto (PNG 28 MB) |
| Animação | `character_anims.glb` por corpo: 6 clipes (`walk` 0,97 s, `idle` 4 s, `sit`, `lay`, `drink`, `drink_sit`), 213 canais, interpolação `LINEAR`, translação/rotação/escala, 72 nós; `clips.json` com duração, altura de contato e velocidade (1,31 tiles/s). Origem: Mixamo (retarget por script) e IK de dois ossos |
| Props | `cup.glb`, `can.glb` (112 KB) |
| Tiers | Low ≈ 6 mil tris/512 px/sem sombra/sem contorno; Mid ≈ 12 mil/1024/sombra 1024/MSAA 4×; High completo/2048/sombra 2048 |
| Otimizações | Atlas único de pele+rosto (1 draw call), mesclagem de malhas por avatar, cabeça com malhas próprias nos tiers com morph (6 draw calls) |
| Tamanho total | **567 MB** (`assets/`: lod1 55 MB, lod2 7,2 MB, original 22 MB, models 36 MB, texturas 90+328+28 MB) |
| Bug conhecido | Skinning por *storage buffer* corrompe no Adreno (Bevy #24926); o workaround do cliente foi usar *uniform buffer*. **Relevante para o `CajuRHIVulkan` no S22+** (§5) |

### 1.3 Licenças (decisivo para o repositório do Caju)
- **Código** dos dois repositórios: o `resortclient` declara `MIT OR Apache-2.0`; o Caju é MIT. Do `toon-characters-bevy` não há arquivo de licença no clone `(?)` (confirmar com o dono; é dele).
- **Pacote de personagens (Rukha93, Unity "Modular Anime Character")**: licença **limitada, não redistribuível** (ADR 0015 e `pipeline-personagens-toon.md` do `resortclient`; o commit do protótipo diz "character assets (private repo only)"). **Não pode entrar no repositório do Caju** (MIT, público). Isso inclui GLBs convertidos, texturas e derivados (LODs, atlas, `.basis`).
- **Animações Mixamo**: uso em jogo costuma ser permitido, redistribuição avulsa não `(?)`; tratar como não redistribuível até confirmar.
- **Fonte Inter** (OFL, com `OFL.txt`): pode ir ao repositório com o arquivo de licença. **Ícones Phosphor** (MIT `(?)`, conferir): idem, com aviso.
- **Som da loja**: gerado por script no `resortclient`; o slice gera o seu (tom sintético) e não depende de arquivo de terceiros.

**Consequência (regra proposta):** os assets do pacote ficam **fora do Git do Caju**, em pasta local apontada por variável de ambiente (`CAJU_SLICE_ASSETS`), listada no `.gitignore`. **O CI nunca vê esses assets**: testes e goldens de CI usam **assets sintéticos** (esqueleto de poucos joints e malha gerados por código). Só a medição em aparelho (M4) e o uso local usam o pacote real. Isso também é o que as trilhas A-1/AN-1/R-1 já precisam para testar headless.

## 2. Mapeamento: feature → trilha → o que dá hoje

### 2.1 Estado verificado em `main` (57fcb8d)
Pronto: `CajuMath` (vetores, `Mat4`, `Quat`, interseção raio–plano/AABB/triângulo), `CajuCore` (ECS, `Query`, agendador, mensagens, estados), `CajuScene` (Transform e hierarquia), `CajuAssetsCore` (glTF/GLB parcial, PNG com decodificação, KTX2 só leitura de cabeçalho, JPEG só metadados, meshopt), `CajuRHI` + Metal (backend nulo e Metal; Vulkan só o triângulo), `CajuText` (fonte TrueType, layout, MSDF, modelo de edição), `CajuUILayout` (layout e *hit-test*), `CajuPhysicsSpatial` (BVH, raio), `CajuPlatform`.
**Só marcador de 5 linhas**: `CajuRender`, `CajuAnim`, `CajuUI`, `CajuInput`, `CajuAssets`, `CajuAudio`.

**Lacuna encontrada (não está nos briefs):** o parser glTF atual (`GLTFParser`/`GLTFDocument`) expõe *buffers, accessors, meshes, nodes, scenes* e só **contagens** de materiais, texturas e imagens. **Não lê `skins` (joints, inverse bind), `animations` (canais, samplers), `targets` de morph, nem dados de material** (`baseColorFactor`, `KHR_materials_specular`, `extras.targetNames`). O slice precisa de skins e animações (AN-1) e, para expressões, de morph. Alguém precisa ampliar `CajuAssetsCore` (hoje trilha P-2, encerrada). **Proposta: incluir na A-1 (ou numa A-1b curta) a extensão do parser para skins/animações/materiais**, com fuzz herdado de P-2; morph fica para depois (§2.3).

### 2.2 Tabela
Legenda de "Hoje": ✅ dá para portar já (lógica pura, testável headless); 🟡 parcialmente; ⛔ bloqueado pela trilha.

| # | Feature do slice | Trilhas que habilitam | Hoje |
|---|---|---|---|
| 1 | **Modelo da sala**: *heightmap* → tiles, paredes do fundo, postes, `tile↔mundo` | só lógica pura (módulo do slice, §3.0) + `CajuMath` | ✅ portável (`room.rs` é lógica pura testada) |
| 2 | **Renderizar sala** (piso, paredes, luz direcional, 1 sombra, parede translúcida) | **R-1a** (extração, unlit/PBR simples, luz) e **R-1b** (sombra); *blend* alfa para parede/ghost **não está explícito no brief da R-1** | ⛔ R-1a |
| 3 | **Câmera**: enquadrar, seguir (suavização), limites, zoom | `CajuMath` + R-1a (matrizes de visão/projeção) ; lógica (`fit_distance`, `follow_step`, `clamp_to_room`, zoom) é pura | ✅ lógica; ⛔ ver na tela |
| 4 | **Toque/clique → tile** | **I-1** (ponteiro unificado, tap, pan, pinch), `CajuMath.intersects(plane)`; **PH-1** só se houver picking por móvel/avatar | 🟡 matemática do raio→tile ✅; eventos reais ⛔ I-1 |
| 5 | **Caminho e movimento** (o servidor fazia): A* local + interpolação ao longo de waypoints, giro | ECS + `CajuScene` | ✅ (lógica nova, não existe no cliente: ver §4) |
| 6 | **Carregar o personagem** (GLB, texturas, catálogo) | **A-1** (`AssetServer`, handles), **A-2** (texturas), extensão do parser (§2.1) | ⛔ A-1; PNG ✅ |
| 7 | **Desenhar o personagem estático** (corpo + cabeça + 1 roupa) | R-1a, A-1; malha *skinned* em pose de repouso já está no espaço de repouso, dá para desenhar **sem skinning** | ⛔ R-1a/A-1 |
| 8 | **Skinning e animação** (`idle`, `walk`, `sit`) | **AN-1** (clipes, player, crossfade, pose) + **R-1b** (skinning na GPU); **ADR 0027** define a fronteira | ⛔ AN-1/R-1b |
| 9 | **Vestir** (roupa por slot, esconder partes do corpo cobertas, trocar peça) | A-1 + AN-1 (**vários meshes compartilhando um esqueleto**, ligação por nome de joint) + lógica de catálogo | 🟡 catálogo/regras ✅ (`BODY_PARTS`, `hides`); render ⛔. **Contrato a pedir à AN-1/R-1b: N malhas, 1 paleta de joints** |
| 10 | **Cor do personagem (shader toon)**: máscara RGB em 3 regiões, rampa, contorno falso, *rim* | **R-1** precisaria de material customizado/shader próprio (Slang, ADR 0001). O brief só fala em "unlit + PBR simples" | ⛔ **decisão de escopo da R-1** (pergunta ao dono, §6) |
| 11 | **Expressões/piscar** (morph targets, 33 shapes) | **Nenhuma trilha**: nem parser, nem render, nem AN-1 citam morph | ⛔ fora do slice (§6) |
| 12 | **LOD e *tier* por aparelho**; atlas de pele+rosto; mesclagem de malhas | v1.0 (plano: "LOD" depois do slice); otimizações do protótipo | fora: o slice usa **um** LOD fixo e mede draw calls antes de otimizar |
| 13 | **HUD** (saldo prata/ouro, botão Loja) | **U-1a** (DSL, `@State`, display list) + **U-1b** (batcher, MSDF) ; `CajuText` ✅ | 🟡 texto ✅; DSL/render ⛔ |
| 14 | **Loja** (menu em árvore, grade rolável, busca, preço, estado "sem saldo", compra) | U-1a (widgets: lista rolável, grade, campo de texto com `CajuTextEditorModel` ✅), U-1b, **I-1** (rolagem por arrasto) | 🟡 lógica pura ✅ (`menu_rows`, `filter_offers`, `can_afford`, `press_category`); UI ⛔ |
| 15 | **Som de compra/ganho** | **AU-1** (`miniaudio`, target C via S-0) | ⛔ AU-1 |
| 16 | **Móveis** como cuboides, **modo construção** (ghost verde/vermelho, giro, validação de tiles) | R-1a (cuboides, alfa), I-1, PH-1 (picking) ; validação de grade é lógica pura | 🟡 lógica ✅; render ⛔; **opcional no slice** |
| 17 | **Pets** (cachorro skinned) | mesma cadeia do personagem (6–9) | fora do primeiro slice |
| 18 | **Rede, login, navegador, criador, inventário, perfil** | — | **fora do slice** (substituídos por dados locais, §4) |

### 2.3 O que o brief da Onda 1 não cobre e o slice exigiria
1. Parser glTF de skins/animações/materiais (§2.1).
2. Material/shader customizável na R-1 (toon por máscara). Alternativa barata: **cor chapada** por material usando `flat_color`/`a2` do `materials.json` como `baseColor` no PBR simples, aceitando visual "sem toon" até a fatia de shader (§3, F7).
3. *Blend* alfa em R-1a (parede translúcida, ghost de construção). Alternativa: parede sempre opaca no primeiro slice.
4. Morph targets (expressões). Alternativa: cabeça estática (`lod2`) no slice.
5. Esqueleto compartilhado por várias malhas (roupa). Precisa estar no contrato da AN-1/R-1b (ADR 0027).
6. Alvo de **código do jogo** no pacote (§3.0): exige `Package.swift`, portanto o S-0.

## 3. Fatias incrementais

### 3.0 Onde o código do slice vive (pedido ao S-0)
O `Package.swift` está trancado. Proposta para o **PR dedicado do S-0** (que já altera o pacote): dois alvos novos.
- `CajuSliceGame` (biblioteca): **lógica pura do jogo**, sem GPU: sala, caminho, câmera, estado da loja e carteira, catálogo, backend local. Depende só de módulos da engine. Testes em `CajuSliceGameTests`. É onde a maior parte do que "dá para portar hoje" entra.
- `CajuVerticalSlice` (executável, em `Hosts/` ou `Sources/`): cola `CajuSliceGame` com Platform, Render, UI, Input, Audio. Única borda onde Foundation (leitura de JSON e de arquivos) é permitida (ADR 0005).
Enquanto o S-0 não existe, **nada do slice é codificado**; a F0 abaixo só prepara dados e contratos.

Convenção: cada fatia termina com um **teste headless** (sintético) e, quando houver tela, uma **captura/golden** local (com assets reais) e uma linha em `docs/standards/performance.md`.

### 3.1 Fatias (em ordem)
Duas faixas independentes (mundo e UI) que se encontram na F8.

| Fatia | Entrega | Depende de | Pronto quando (CI, sintético) | Medição |
|---|---|---|---|---|
| **F0** Preparação (agora, só docs) | Este plano aceito; **dados locais de exemplo** definidos (§4); script de **preparo do subconjunto de assets** (§3.2); `.gitignore` e variável `CAJU_SLICE_ASSETS`; pedido de contratos à A-1/R-1/AN-1 (§2.3) | aceite do dono | — | — |
| **F1** Lógica da sala + caminho + câmera | `CajuSliceGame`: *heightmap*→tiles, paredes, `tile↔mundo`, A*, interpolação de waypoints, câmera (enquadrar/seguir/zoom), raio→tile | **S-0** (alvos novos) | Testes de propriedade (caminho válido, câmera dentro da sala, tile sob o raio) com PCG semeado; porta os testes de `room.rs`/`camera.rs`; zero alocação em `follow_step` | CPU de A* em sala 12×10 `(?)` |
| **F2** Sala na tela | Piso e paredes procedurais, luz direcional, câmera fixa; marcador (cápsula/cubo) no tile; clique/toque escolhe o tile e o marcador **anda** pelo caminho local | F1, **R-1a**, **I-1** (tap/pinch), V-1 só para Android | Golden Metal da sala; testes de gestos com sequência sintética (tap vs. pinch vs. arrasto) | p50/p95 de quadro e draw calls (iPhone) `(?)` |
| **F3** Personagem estático | Corpo + cabeça `lod2` + 1 roupa do pacote real, **cor chapada** do `materials.json`, em pose de repouso, parado no tile | **A-1** (+ extensão do parser), A-2 (PNG basta no início), R-1a | Teste do carregamento com GLB **sintético**; local: captura com assets reais | memória e tempo de carga `(?)` |
| **F4** Skinning + idle/walk | Avatar anda com `walk`, para com `idle`; velocidade do clipe (1,31 tiles/s) casa com o movimento; `sit` ao tocar num assento (opcional) | **AN-1**, **R-1b** (skinning), V-1 para S22+ (cuidado com Adreno, §5) | Testes de propriedade de amostragem (quat normalizado, loop); golden de pose; benchmark de amostragem `(?)` | custo de skinning por avatar `(?)`; **marco M3 (parcial)** |
| **F5** Vestir | Trocar top/bottom/sapato/cabelo por catálogo local; esconder partes do corpo cobertas; vários avatares (2–5) para medir | F4 + contrato "N malhas, 1 esqueleto" | Teste de ligação por nome de joint com esqueleto sintético; regras de `hides` | draw calls e memória com N avatares `(?)` |
| **F6** HUD e loja (faixa UI, pode começar **antes** da F2) | `CajuSliceGame`: loja pura (árvore, filtro, preço, compra local, saldo). UI: DSL → árvore retida → layout → *hit-test* **headless**, depois render | F1 (lógica), **U-1a** (DSL/widgets), **U-1b** (render), **I-1** (rolagem), CajuText | Testes headless da loja e da UI (ofertas filtradas, botão desabilitado, compra debita); goldens de UI | **≤ 40 draw calls na tela de loja** (meta do brief); relayout < 1 ms `(?)` |
| **F7** Som e acabamento visual | Som de compra (**AU-1**, tom sintético); **shader toon** por máscara + contorno (se o dono aprovar na R-1/ADR 0023); sombra projetada; parede translúcida | AU-1, R-1b, decisão §6 | Teste de ciclo de vida do áudio (dispositivo nulo); golden do toon | custo do toon por avatar `(?)` |
| **F8** Integração e medição (**M4**) | Uma cena: sala, câmera que segue, toque, avatar animado/vestido, HUD e loja, som; cenário de referência fixo | F2, F4, F5, F6, F7 + gate da Onda 1 | Teste de integração headless da cena; regressão > 10 % bloqueia | **NFR-001/002/003/008/009** em iPhone 16 Pro e S22+ |
| **F9** Opcionais (só depois do M4) | Móveis cuboides e modo construção (ghost, giro, picking via PH-1); pet; expressões (morph, exige trilha nova); LOD/atlas/mesclagem; criador de personagem | M4 | — | — |

Ordem de dependência real: **F1 → F2 → F3 → F4 → F5** (mundo) e **F1 → F6** (UI) em paralelo; F7 e F8 fecham. A F1 e a lógica da F6 são o que realmente se pode fazer logo após o S-0, sem esperar R-1, A-1 ou U-1.

### 3.2 Preparo local dos assets (F0)
Script (Python puro, local, **não versionar o resultado**) que copia do `toon-characters-bevy` para `$CAJU_SLICE_ASSETS` um **subconjunto mínimo**: `F_body` e `F_head.001` em `lod2/original`, uma peça de cada slot em `lod2/models` (`F_top.001_shirt`, `F_bot.001_pants`, `F_shoes.001_boots`, `C_hair_short.001`), `animations/F/{character_anims.glb,clips.json}`, `materials.json`, `avatar_catalog.json` e `items/outfits.json`, mais as texturas PNG dessas peças. Tamanho estimado < 30 MB `(?)` (corpo F tem texturas de 2048 px com ≈ 2,6 MB cada; reduzir na T-1 quando existir). O segundo corpo (`M`) e o restante do catálogo entram só na F5.

## 4. Dados locais e mocks no lugar do servidor
Princípio: **a lógica do jogo fala com um protocolo `SliceBackend`** (Swift), com uma implementação `LocalBackend`. Assim o slice não consome servidor e, se o dono quiser, um `NetBackend` sobre `CajuNet` entra depois sem mudar o jogo. Dados em JSON lidos **na borda** (executável), decodificados para tipos de valor.

| O servidor fazia | No slice (local) | Dado de partida |
|---|---|---|
| Sessão/login/perfil | Perfil fixo carregado de arquivo | `profile_alice.json` (do `resortclient`) como modelo |
| `room_snapshot` (layout, avatares, itens, pets) | Fixture de sala embutida (`lobby_12x10`, porta em `(1,5)`; opcionalmente uma sala em L para testar paredes) | `contract/fixtures/room_snapshot.json` |
| `MOVE_REQUEST` → `AVATAR_PATH` | **A\* local** na grade (o cliente de referência *nunca* calculava rota; regras do servidor para diagonais e esquinas **não foram lidas** `(?)`, adotar 4 vizinhos e registrar) | — |
| Aparência | `avatar_appearance.json` + catálogo local; cores por grupo do `materials.json` | `contract/fixtures/avatar_appearance.json`, `avatar_catalog.json` |
| Carteira e heartbeat de moedas | `Wallet` local (prata/ouro) com saldo inicial fixo; sem heartbeat | `contract/fixtures/wallet.json` |
| Catálogo da loja e compra | Fixture + transação local (debita, adiciona ao inventário local, mensagem de sucesso/erro) | `contract/fixtures/shop_catalog.json` (hoje com 1 oferta: **ampliar** com ~12 ofertas e 2–3 categorias para estressar rolagem e busca) |
| Catálogo de móveis | JSON local | `contract/furniture-catalog.json` |
| CDN de assets (manifest, hash, tiers) | Pasta local `CAJU_SLICE_ASSETS`; `AssetServer` da A-1 lê do disco | §3.2 |
| Postura (`sit`/`lay`), expressão, objeto na mão | Estado local do avatar | fixtures `avatar_posture_changed.json` etc. |

Observação de licença: os arquivos de `contract/` são do projeto do dono e podem ser copiados como fixtures; **os do pacote de personagens, não** (§1.3).

## 5. Riscos
1. **Licença do pacote de personagens** (§1.3): vazar assets para o Git do Caju seria violação. Mitigação: pasta local ignorada, CI sintético, checagem no `scripts/check-forbidden.sh` por extensão/pasta `(?)`.
2. **Sem cor sem o shader toon**: as texturas são máscaras RGB, não albedo. Sem o shader (ou o fallback de cor chapada) o personagem aparece cinza/errado. Decisão de escopo da R-1.
3. **`.basis` ≠ KTX2**: o `CajuAssetsCore` lê KTX2, e o pacote traz Basis UASTC. Opções: usar PNG até a T-1 converter (A-2 e T-1 pendentes), ou converter offline para KTX2/ASTC. Um transcodificador Basis é dependência C dedicada (ADR 0017); o slice **não deve depender** dele.
4. **Parser glTF sem skins/animações/morph/material** (§2.1): se não entrar na A-1, a F3/F4 ficam bloqueadas.
5. **Skinning no Adreno 730 (S22+)**: o Bevy teve bug de skinning por *storage buffer* (issue #24926); o `CajuRHIVulkan` deve testar o caminho escolhido cedo, com um *golden* de pose em aparelho, antes de a F4 depender dele.
6. **Várias malhas, um esqueleto**: o modelo de roupa depende disso; se o ADR 0027 não previr, o vestir (F5) vira retrabalho.
7. **Orçamento de draw calls**: o protótipo gastou 6 draw calls só na cabeça e precisou de atlas e mesclagem; o teto do slice é ≤ 300 totais, UI ≤ 40. Medir F5 com N avatares antes de otimizar.
8. **Tamanho e tempo**: corpo F tem texturas de 2048 px (≈ 2,6 MB cada); memória residente do cenário de referência ≤ 600 MB, GPU ≤ 300 MB `(?)`.
9. **Slice grande demais**: o jogo de referência tem ≈ 31 mil linhas; o slice é um recorte (§3.1, F9 fora). Risco de "portar o jogo"; manter a lista de exclusões (linha 18 da §2.2).
10. **`Package.swift` como gargalo**: os alvos do §3.0 precisam entrar no S-0, ou o slice só começa depois de um PR dedicado.
11. **Versões**: o `resortclient` usa Bevy 0.19 e o `toon-characters-bevy` 0.20; os números de desempenho do protótipo **não são comparáveis** com os do Caju. Servem como referência de intenção, não como meta.

## 6. Perguntas para o dono
1. **Prioridade dentro do `resortclient`**: confirmar o recorte do slice (sala + câmera + toque + avatar andando + loja com saldo). Algo a mais é prioridade (móveis e construção? pet? criador de personagem?) ou algo do recorte pode sair (som, loja)?
2. **Visual do personagem**: o slice exige o **shader toon** (e a R-1 ganha material customizado) ou aceita **cor chapada** até depois do M4?
3. **Expressões e piscar**: ficam fora (cabeça estática `lod2`) ou valem uma trilha nova (morph targets no parser, na R-1b e na AN-1)?
4. **Licença**: confirmar que o pacote Rukha93 (e o Mixamo) **não** podem ser redistribuídos e que o plano "assets locais fora do Git" está certo; informar a licença do `toon-characters-bevy` (código) e dos ícones Phosphor.
5. **Onde mora o slice**: aprova os alvos `CajuSliceGame` e `CajuVerticalSlice` no PR do S-0? Ou prefere repositório próprio?
6. **Regras de movimento**: confirmar 4 vizinhos (como no servidor?) para o A\* local; ler o servidor, se quiser fidelidade.
7. **Móveis**: o slice usa cuboides (como o cliente de referência, que não tem GLB de móvel) ou o dono tem modelos de móveis para o slice?
8. **Aparelhos**: o slice no iPhone 16 Pro e S22+ continua o plano; Android entra na F4 ou só na F8?

## 7. Documentos que este PR atualiza
`docs/planejamento-engine.md` (§8, "Depois": link para este plano). Nenhum ADR novo: não há decisão tomada; as perguntas da §6 viram ADR (ou emenda do 0023/0027) quando o dono responder.

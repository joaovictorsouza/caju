# ADR 0028: Política de áudio e dependência sobre miniaudio (AU-1)

**Status:** Aceito (2026-11-15; implementado na trilha AU-1).

## Contexto
O Caju precisa de uma camada de áudio multiplataforma (iOS 17+, Android API 29+, macOS 14+ e Linux no CI) com fontes 2D/3D (atenuação por distância e *pan*), mixagem por grupos/buses, decodificação em memória e pausa/retomada ligadas ao ciclo de vida do aplicativo.

O [ADR 0005](0005-dependencias-e-foundation.md) adotou o `miniaudio` (`0.11.26`) como target C vendorizado (`Sources/CMiniaudio`), compilado com `MA_NO_ENCODING`. No `Package.swift`, `CajuAudio` (Camada 3) depende de `CajuCore`, `CajuMath` e `CMiniaudio`, sem dependência direta de `CajuPlatform` e sem `Foundation` no núcleo.

## Decisão
- **Encapsulamento total da API C (`internal import CMiniaudio`):** nenhum tipo, ponteiro ou constante `ma_*` vaza pela API pública do `CajuAudio`. Códigos `ma_result` são convertidos para o erro tipado `CajuAudioError` (`throws(CajuAudioError)`), sem alocação de `String` no caminho de erro.
- **Somente decodificação e reprodução (`MA_NO_ENCODING`):** clipes são criados a partir de PCM `Float32` intercalado ou decodificados em memória (`ma_decode_memory`: WAV, FLAC, MP3). Não há suporte a captura/gravação nem codificação.
- **Handles geracionais e compartilhamento seguro de PCM:** `CajuAudioClipHandle`, `CajuAudioBusHandle` e `CajuAudioSourceHandle` usam índice + geração (`CajuAudioHandle<Tag>`). Múltiplas fontes compartilham o mesmo buffer PCM imutável do clipe por meio de um `ma_audio_buffer` leve por instância (cursor próprio); a liberação do buffer PCM e de buses pais acontece na thread principal após `ma_sound_uninit`, garantindo ausência de *use-after-free* mesmo se um clipe ou bus for destruído enquanto houver fontes ativas.
- **Callback de áudio sem alocação nem ARC (`@convention(c)`):** `cajuAudioDataCallback` é uma função `@convention(c)` (`ma_device_data_proc`), impedida em compilação de capturar contexto ou *closures* Swift. Seu `pUserData` aponta diretamente para `ma_engine` alocado manualmente (sem `Unmanaged` nem classe gerenciada por ARC), e seu corpo executa apenas verificação de ponteiro e `ma_engine_read_pcm_frames` — zero `Array`, zero `Dictionary`, zero `retain`/`release`, zero *locks* Swift e zero alocação dinâmica.
- **Espacialização 2D/3D alinhada a `CajuMath`:** usa o sistema de mão direita do `CajuMath` (+X direita, +Y cima, -Z frente) via `CajuVec2`, `CajuVec3` e `CajuQuat`. `CajuAudioSpatialMath` implementa de forma pura e determinística a atenuação por distância (`none`, `inverse`, `linear`, `exponential`), *pan* estéreo e cones direcionais; fontes `.planar2D` usam `CajuAudioSpatialMath` e se atualizam quando o ouvinte principal muda, enquanto fontes `.spatial3D` usam o espacializador nativo do `miniaudio`.
- **Mixagem hierárquica por buses (`ma_sound_group`):** `CajuAudioBusHandle` encapsula `ma_sound_group` com suporte a hierarquia pai/filho, controle independente de volume, *pan*, *pitch* e pausa/retomada por bus.
- **Três modos de backend (`CajuAudioBackend`):** `.automatic` (backend nativo do SO: CoreAudio/AAudio/OpenSL ES/ALSA), `.null` (`ma_backend_null` com thread de áudio real para testes headless/CI) e `.offline` (`noDevice = true` com `renderFrames` determinístico para testes de mixagem e espacialização).
- **Ciclo de vida desacoplado de `CajuPlatform`:** `CajuAudioLifecycleEvent` espelha `CajuLifecycleEvent` (`Sources/CajuPlatform`) seguindo o padrão de tipos paralelos do [ADR 0015](0015-contrato-rhi-e-platform.md), evitando dependência extra no `Package.swift`. `pause()` e `resume()` chamam `ma_engine_stop`/`ma_engine_start` de forma idempotente, preservando os cursores das fontes.

## Alternativas
- **Mixer próprio em Swift sobre AVAudioEngine/Oboe/AAudio:** descartado pelo ADR 0005 pelo custo de manter dois backends de áudio de baixo nível e reamostragem/mixagem em tempo real.
- **Passar `Unmanaged<CajuAudioEngine>` para o `dataCallback`:** evitado porque exigiria `takeUnretainedValue()` ou `retain`/`release` na thread de áudio em tempo real.
- **Adicionar `CajuPlatform` como dependência de `CajuAudio` em `Package.swift`:** desnecessário nesta etapa; o tipo paralelo `CajuAudioLifecycleEvent` mantém o grafo de dependências enxuto e pode ser convertido no host ou via ponte em PR dedicado.

## Consequências
- O código compila em Swift 6 estrito (`-warnings-as-errors`), sem `Foundation` e sem vazamento de `CMiniaudio`.
- A suíte headless valida ciclo de vida completo com dispositivo nulo (`init`, `play`, `pause`, `resume`, `shutdown`) e mixagem determinística no backend offline em macOS e Linux.
- Impacto de tamanho de binário em `.apk`/iOS e latência em aparelho real permanecem como `(?)` até medição no gate da Onda 1.

## Quando reabrir
- Se o jogo precisar de gravação/captura de microfone (reavaliar `MA_NO_ENCODING`).
- Se for necessário DSP customizado em Swift no grafo de mixagem ou *streaming* assíncrono de faixas longas direto de arquivo/VFS.
- Se a integração com `CajuScene`/`CajuPlatform` justificar adicionar essas dependências em `Package.swift` via PR dedicado.

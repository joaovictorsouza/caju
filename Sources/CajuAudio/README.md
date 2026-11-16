# CajuAudio

Engine de áudio 2D/3D sobre `miniaudio` (`CMiniaudio`, versão `0.11.26`, `MA_NO_ENCODING`), sem vazamento de tipos C e sem alocação no *callback* de áudio ([ADR 0028](../../docs/adr/0028-audio-miniaudio.md)).

- **Camada:** 3 (dependências só para baixo; ver §5 do plano).
- **Trilha dona:** AU-1 (Onda 1).
- **Estado:** implementado (`CajuAudioEngine`, clipes em memória/decodificados, buses hierárquicos, fontes 2D/3D, `CajuAudioSpatialMath`, backends `.automatic`/`.null`/`.offline`, ciclo de vida `pause`/`resume`/`shutdown`).

## Dependências
- `CajuCore`
- `CajuMath` (`CajuVec2`, `CajuVec3`, `CajuQuat`, `CajuScalar`)
- `CMiniaudio` (importado como `internal import CMiniaudio`; nunca exposto na API pública)

## Garantia de zero alocação no *callback* de áudio
O *callback* registrado no dispositivo (`cajuAudioDataCallback` em `CajuAudioMiniaudioMap.swift`) é garantido livre de alocações e de ARC por construção:
1. É uma função `@convention(c)` (`ma_device_data_proc`): o compilador Swift proíbe capturar qualquer variável, referência ou *closure*.
2. `pUserData` aponta diretamente para `ma_engine` alocado manualmente via `UnsafeMutablePointer<ma_engine>.allocate` (sem `Unmanaged` nem instância de classe Swift).
3. O corpo não usa `Array`, `Dictionary`, `String`, *locks* Swift nem despacho dinâmico — apenas valida os ponteiros e chama `ma_engine_read_pcm_frames`.
4. `ma_engine_uninit` para e junta a *thread* de áudio antes de qualquer liberação de memória no `shutdown()`.

## Decisões relevantes
- **Erros tipados:** toda operação falível usa `throws(CajuAudioError)` sem `String` alocada no caminho de erro e sem `!`/`try!`/`fatalError`/`precondition`.
- **Handles geracionais:** `CajuAudioClipHandle`, `CajuAudioBusHandle` e `CajuAudioSourceHandle` invalidam referências antigas após `destroy*`.
- **Ciclo de vida:** `CajuAudioLifecycleEvent` espelha `CajuLifecycleEvent` (`CajuPlatform`) sem adicionar dependência ao `Package.swift` (padrão do ADR 0015). `pause()` e `resume()` param/retomam o dispositivo preservando os cursores.
- **Somente decodificação:** compilado com `MA_NO_ENCODING` (sem gravação/codificação). Custo de binário em aparelho e latência em iPhone 16 Pro / Galaxy S22+ seguem pendentes de medição `(?)`.

## Como testar
`swift test --filter CajuAudio` na raiz (executa as suítes em `Tests/CajuModulesTests/CajuAudioTests.swift`, cobrindo dispositivo `.null` headless com 50 ciclos de ciclo de vida, backend `.offline` determinístico, espacialização 2D/3D, buses de mixagem, decodificação WAV em memória e entradas hostis).

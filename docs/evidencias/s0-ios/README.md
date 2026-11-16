# Evidências S-0: iPhone 16 Pro (gate do ADR 0006, parte iOS)

Aparelho: iPhone 16 Pro (`iPhone17,1`, iOS 27.2), pareado por cabo no MacBook Pro M1 (macOS 26.6, Xcode com Swift 6.4.2). Host: `Hosts/Apple` (`CajuHost-iOS`), build **Debug** assinado, 60 Hz (display link do host; `thermalState` = nominal). Medido em 2026-11-15.

## Como reproduzir
```sh
cd Hosts/Apple && xcodegen generate
xcodebuild -project CajuHost.xcodeproj -scheme CajuHost-iOS -destination 'id=<UDID>' -allowProvisioningUpdates DEVELOPMENT_TEAM=<time> build
xcrun devicectl device install app --device <UDID> <CajuHost-iOS.app>
xcrun devicectl device process launch --device <UDID> --terminate-existing dev.caju.host -- -caju-gate
xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer --domain-identifier dev.caju.host --source Documents/gate.log --destination gate.log
```
Com o aparelho desbloqueado e Bloqueio Automático em "Nunca" (tela bloqueada suspende o app e invalida a medição). `-caju-soak-frames N` muda a duração do soak (padrão 18 000 quadros, 5 min).

## Resultados
| Critério (ADR 0006) | Resultado | Arquivo |
|---|---|---|
| 50 ciclos de superfície (liberar, recriar, tamanho alternado) | ΔRSS **0,016 MB** (5 min) e 0,06 MB (20 s); recursos vivos 12 → 10 (transientes liberados; nenhum vazamento) | `gate-iphone-16-pro-soak-*.log` |
| 5 voltas reais de background/resume (Início e reabrir, feito pelo dono) | RSS 33,2 → 29,4 MB; +0,17 MB nas voltas 2 a 4; sem erro | `toque-e-background-iphone-16-pro.log` |
| Soak 5 min (18 000 quadros, cubo + UI) | intervalo entre quadros p50 = p95 = 16,67 ms, máximo 16,70 ms; nenhum quadro perdido; ΔRSS 1,05 MB (inclui ~0,3 MB dos vetores de amostras do próprio harness) | `gate-iphone-16-pro-soak-5min.log` |
| Toque | 8 acertos seguidos no botão, cubo para e volta a girar | `toque-e-background-iphone-16-pro.log` |
| Aliasing por heap | **Não aplicável**: o Metal ainda não implementa (ADR 0015); vira item da R-1 | n/a |

## Ressalvas
- O p95 do intervalo de quadro é o período do vsync (60 Hz): prova que **não houve quadro perdido**, não custo de CPU. O "CPU por quadro" do log (≈ 16,6 ms) inclui a espera pelo drawable e **não** é custo de CPU; custo real exige Instruments ou um alvo sem vsync `(?)`.
- Build Debug (`-Onone`); Release deve ser melhor. Cena trivial (cubo + UI): não representa o vertical slice.
- O ProMotion (120 Hz) não foi exercitado: o host roda a 60 Hz `(?)`.
- Foi achado e corrigido um bug real do host: no iOS o espaço local do `onTapGesture` começa na área segura (~59 pt) e o toque errava o botão; passa a usar o espaço global.

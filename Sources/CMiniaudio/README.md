# CMiniaudio

Alvo C com o [miniaudio](https://github.com/mackron/miniaudio) **0.11.26** vendorizado (cabeçalho único, sem modificações), política do ADR 0005.

- Na Apple a implementação compila como Objective-C (`miniaudio_apple.m`): o backend CoreAudio importa AVFoundation e falha em `.c` no build de iOS. Fora da Apple vale `miniaudio.c`. Se a AU-1 desligar o carregamento dinâmico, precisa linkar `AudioToolbox`, `CoreAudio` e `AVFoundation`.
- Só o `CajuAudio` consome este alvo (trilha AU-1, ADR 0028); o resto da engine nunca importa `CMiniaudio`.
- Backends: CoreAudio (iOS/macOS) e AAudio/OpenSL ES (Android), carregados por `dlopen` (comportamento padrão do miniaudio, sem frameworks extras no link).
- Versão, origem e hash em `VERSION`. Para atualizar: PR dedicado que troca `include/miniaudio.h`, `VERSION` e mede o tamanho do binário.
- Fora do `swift-format` e do `check-forbidden.sh` (código de terceiros).

// Implementação do miniaudio fora da Apple (cabeçalho único, versão fixa; ver VERSION).
// Na Apple o backend CoreAudio usa Objective-C (AVFoundation): ver miniaudio_apple.m.
// Opções de compilação ficam em Package.swift (cSettings), nunca aqui.
#ifndef __APPLE__
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
#endif

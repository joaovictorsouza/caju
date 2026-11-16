// Implementação do miniaudio na Apple, compilada como Objective-C: o backend CoreAudio importa
// AVFoundation, que exige o recurso `objc` (o mesmo código em .c falha no build de iOS).
#ifdef __APPLE__
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
#endif

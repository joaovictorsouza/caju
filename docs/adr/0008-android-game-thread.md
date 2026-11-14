# ADR 0008: Android: Game Thread própria e build nativo

**Status:** Aceito. Corrige o §3.4 do plano original (`@MainActor` para tudo).

## Decisão
- No Android, o laço de jogo e o render rodam em **Game Thread própria**, fora da UI thread do Java; a ponte com a `Activity` (ciclo de vida, insets, IME, entrada) é por filas.
- No iOS/macOS, o laço pode rodar na thread principal por *display link*; apenas a borda com UIKit é `@MainActor`.
- **Build Gradle/CMake/JNI/empacotamento de `libswiftCore.so`** é trilha própria (TB-Android, ADR 0006).
- CI compila para `aarch64-linux-android` desde o M0.

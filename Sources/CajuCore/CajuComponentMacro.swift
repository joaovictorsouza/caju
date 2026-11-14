/// Gera a conformância a `CajuComponent` e o `componentID` estático (ADR 0020).
///
/// ```swift
/// @Component(id: 48)
/// struct Position { var x, y: Float }
/// ```
///
/// `id` é um literal inteiro em `0..<64` (faixas: 0–15 núcleo, 16–47 módulos, 48–63 jogo). A macro só
/// se aplica a `struct`/`enum`; duplicidade de ID entre tipos continua sendo detectada pelo mundo
/// (`CajuWorldError.componentIDConflict`). Declarar `static let componentID` à mão segue válido.
@attached(extension, conformances: CajuComponent, names: named(componentID))
public macro Component(id: UInt8) = #externalMacro(module: "CajuMacrosPlugin", type: "ComponentMacro")

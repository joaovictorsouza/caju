import CajuInput
import CajuMath

/// Conversão de posição de ponteiro (pontos lógicos da superfície) em raio de mundo.
public enum CajuPicking {
    /// Raio unitário que passa pelo pixel/ponto `pointer` de uma viewport `viewportSize`.
    ///
    /// Convenções: origem da tela no canto superior esquerdo (y para baixo); projeção com profundidade
    /// `[0, 1]` (`CajuMat4.perspective`/`orthographic`). A origem do raio é o ponto do plano *near*.
    /// Retorna `nil` para viewport degenerada, matriz não finita ou ponteiro não finito.
    public static func ray(
        pointer: CajuVec2, viewportSize: CajuVec2, inverseViewProjection: CajuMat4
    ) -> CajuRay? {
        guard viewportSize.x > 0, viewportSize.y > 0, viewportSize.x.isFinite, viewportSize.y.isFinite,
            pointer.x.isFinite, pointer.y.isFinite, inverseViewProjection.isFinite
        else { return nil }
        let x = 2 * pointer.x / viewportSize.x - 1
        let y = 1 - 2 * pointer.y / viewportSize.y
        let n = inverseViewProjection * SIMD4<Float>(x, y, 0, 1)
        let f = inverseViewProjection * SIMD4<Float>(x, y, 1, 1)
        guard n.w != 0, f.w != 0 else { return nil }
        let near = CajuVec3(n.x / n.w, n.y / n.w, n.z / n.w)
        let far = CajuVec3(f.x / f.w, f.y / f.w, f.z / f.w)
        return CajuRay(origin: near, normalizingDirection: far - near)
    }

    /// Raio a partir de um evento de ponteiro do `CajuInput`.
    public static func ray(
        event: CajuPointerEvent, viewportSize: CajuVec2, inverseViewProjection: CajuMat4
    ) -> CajuRay? {
        ray(
            pointer: event.position, viewportSize: viewportSize,
            inverseViewProjection: inverseViewProjection)
    }

    /// Raio a partir da posição atual de um ponteiro rastreado (`CajuPointerTable`).
    public static func ray(
        snapshot: CajuPointerSnapshot, viewportSize: CajuVec2, inverseViewProjection: CajuMat4
    ) -> CajuRay? {
        ray(
            pointer: snapshot.position, viewportSize: viewportSize,
            inverseViewProjection: inverseViewProjection)
    }
}

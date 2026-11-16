import CajuCore

/// Componente ECS que referencia um asset carregado via ``CajuAssetHandle``.
///
/// Como componentes do ``CajuWorld`` são `BitwiseCopyable` e não possuem `deinit`, tipos que adotam este
/// protocolo podem usar ``CajuAssetHandleTracker`` para sincronizar `retain`/`release` com o ciclo de
/// vida da entidade.
public protocol CajuAssetComponent: CajuComponent {
    associatedtype Asset: CajuAsset
    /// Handle do asset associado ao componente.
    var assetHandle: CajuAssetHandle<Asset> { get }
}

/// Sincroniza a posse de handles em componentes ``CajuAssetComponent`` do ``CajuWorld``.
///
/// Mantém os buffers pré-alocados para não alocar no quadro estável quando o número de entidades não cresce.
/// Deve ser chamado na *thread* do jogo (por exemplo, em um sistema no estágio `.postUpdate`).
public final class CajuAssetHandleTracker<Component: CajuAssetComponent> {
    private struct TrackedSlot {
        var isTracked = false
        var entityGeneration: UInt32 = 0
        var handle: CajuAssetHandle<Component.Asset> = .invalid
    }

    private var trackedBySlot: [TrackedSlot] = []
    private var activeSlotIndices: [Int] = []

    /// Cria um rastreador com capacidade inicial reservada para `expectedEntities`.
    public init(expectedEntities: Int = 0) {
        let cap = max(0, expectedEntities)
        if cap > 0 {
            trackedBySlot.reserveCapacity(cap)
            activeSlotIndices.reserveCapacity(cap)
        }
    }

    /// Libera handles de entidades removidas/modificadas e retém handles recém-associados.
    public func sync(world: CajuWorld, server: some CajuAssetServing) {
        var i = activeSlotIndices.count - 1
        while i >= 0 {
            let slotIndex = activeSlotIndices[i]
            let tracked = trackedBySlot[slotIndex]
            let entity = CajuEntity(
                index: UInt32(truncatingIfNeeded: slotIndex),
                generation: tracked.entityGeneration
            )
            let stillSame =
                world.contains(entity)
                && world.get(Component.self, of: entity)?.assetHandle == tracked.handle
            if !stillSame {
                _ = server.release(tracked.handle)
                trackedBySlot[slotIndex] = TrackedSlot()
                let lastIndex = activeSlotIndices.count - 1
                if i != lastIndex {
                    activeSlotIndices[i] = activeSlotIndices[lastIndex]
                }
                activeSlotIndices.removeLast()
            }
            i -= 1
        }

        world.forEachEntity(having: Component.self) { entity, component in
            let handle = component.assetHandle
            guard handle != .invalid else { return }
            let slotIndex = Int(entity.index)
            if slotIndex < trackedBySlot.count {
                let current = trackedBySlot[slotIndex]
                if current.isTracked,
                    current.entityGeneration == entity.generation,
                    current.handle == handle
                {
                    return
                }
            } else {
                trackedBySlot.reserveCapacity(slotIndex + 1)
                while trackedBySlot.count <= slotIndex {
                    trackedBySlot.append(TrackedSlot())
                }
            }

            if server.retain(handle) {
                trackedBySlot[slotIndex] = TrackedSlot(
                    isTracked: true,
                    entityGeneration: entity.generation,
                    handle: handle
                )
                activeSlotIndices.append(slotIndex)
            }
        }
    }

    /// Libera todas as posses ainda rastreadas (por exemplo, ao encerrar uma cena).
    public func releaseAll(from server: some CajuAssetServing) {
        for slotIndex in activeSlotIndices {
            let tracked = trackedBySlot[slotIndex]
            if tracked.isTracked {
                _ = server.release(tracked.handle)
                trackedBySlot[slotIndex] = TrackedSlot()
            }
        }
        activeSlotIndices.removeAll(keepingCapacity: true)
    }
}

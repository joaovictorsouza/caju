#if os(Android)
    import CVulkan
    import CajuRHI

    /// Anel linear de uniformes para `setBytes` (ADR 0024): um buffer `HOST_VISIBLE | HOST_COHERENT` mapeado
    /// de forma persistente, sub-alocado em sequência. Cada `submit` marca até onde o anel foi usado; a região
    /// volta a ficar livre quando a *fence* daquela submissão termina. Sem alocação de memória por quadro.
    final class VulkanUniformRing {
        let buffer: VkBuffer
        private let allocation: VmaAllocation
        private let mapped: UnsafeMutableRawPointer
        let capacity: Int
        private let alignment: Int
        private unowned let context: CajuVulkanContext

        private var head = 0
        private var tail = 0
        /// Há bytes escritos desde o último `mark` (pertencem ao *command buffer* em gravação).
        private var pending = false
        private var marks: [(serial: UInt64, end: Int)] = []

        init(context: CajuVulkanContext, capacity: Int) throws(CajuRHIError) {
            self.context = context
            self.capacity = capacity
            alignment = max(Int(context.limits.minUniformBufferOffsetAlignment), 16)
            var bufferInfo = VkBufferCreateInfo()
            bufferInfo.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
            bufferInfo.size = VkDeviceSize(capacity)
            bufferInfo.usage = VkBufferUsageFlags(VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT.rawValue)
            bufferInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE
            var allocationInfo = VmaAllocationCreateInfo()
            allocationInfo.usage = VMA_MEMORY_USAGE_AUTO
            allocationInfo.flags = VmaAllocationCreateFlags(
                VMA_ALLOCATION_CREATE_MAPPED_BIT.rawValue
                    | VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT.rawValue)
            allocationInfo.requiredFlags = VkMemoryPropertyFlags(
                VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.rawValue | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT.rawValue)
            var created: VkBuffer?
            var createdAllocation: VmaAllocation?
            var info = VmaAllocationInfo()
            try vkCheck(
                vmaCreateBuffer(
                    context.allocator, &bufferInfo, &allocationInfo, &created, &createdAllocation, &info))
            guard let created, let createdAllocation, let pointer = info.pMappedData else {
                throw .outOfMemory
            }
            buffer = created
            allocation = createdAllocation
            mapped = pointer
            marks.reserveCapacity(8)
        }

        func destroy() {
            vmaDestroyBuffer(context.allocator, buffer, allocation)
        }

        /// Copia `bytes` para o anel e devolve o *offset*. Espera a GPU só se o anel inteiro estiver em uso.
        func push(_ bytes: UnsafeRawBufferPointer) throws(CajuRHIError) -> Int {
            let size = max(bytes.count, 1)
            guard size <= capacity / 2 else { throw .invalidDescriptor(.exceedsDeviceLimit) }
            reclaim(upTo: context.completedSerial)
            while true {
                let aligned = (head + alignment - 1) / alignment * alignment
                if head >= tail {
                    if aligned + size <= capacity { return commit(at: aligned, size: size, bytes) }
                    if size < tail { return commit(at: 0, size: size, bytes) }  // dá a volta
                } else if aligned + size < tail {
                    return commit(at: aligned, size: size, bytes)
                }
                // Sem marca em voo: o command buffer em gravação sozinho encheu o anel.
                guard let oldest = marks.first else { throw .outOfMemory }
                try context.wait(for: oldest.serial)
                reclaim(upTo: oldest.serial)
            }
        }

        private func commit(at offset: Int, size: Int, _ bytes: UnsafeRawBufferPointer) -> Int {
            if let base = bytes.baseAddress {
                (mapped + offset).copyMemory(from: base, byteCount: bytes.count)
            }
            head = offset + size
            pending = true
            return offset
        }

        /// Chamado a cada submissão: o que foi escrito até aqui vive até a *fence* de `serial`.
        func mark(serial: UInt64) {
            guard pending else { return }
            marks.append((serial, head))
            pending = false
        }

        private func reclaim(upTo serial: UInt64) {
            while let first = marks.first, first.serial <= serial {
                tail = first.end
                marks.removeFirst()
            }
            if marks.isEmpty, !pending {
                head = 0
                tail = 0
            }
        }
    }
#endif

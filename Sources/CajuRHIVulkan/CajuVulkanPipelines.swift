#if os(Android)
    import CVulkan
    import CajuRHI

    /// Módulo de shader com os *bindings* lidos do SPIR-V (`CajuVulkanShaderReflection`).
    struct VulkanShader {
        var module: VkShaderModule
        var bindings: [CajuVulkanShaderReflection.Binding]
    }

    /// Pipeline gráfico com o layout próprio (só os *bindings* que os shaders usam; ADR 0024).
    struct VulkanRenderPipeline {
        var pipeline: VkPipeline
        var layout: VkPipelineLayout
        var setLayout: VkDescriptorSetLayout
        var bindings: [(binding: UInt32, kind: CajuVulkanShaderReflection.DescriptorKind)]
        var colorFormats: [CajuPixelFormat]
        var depthFormat: CajuPixelFormat?
        var sampleCount: Int
    }

    /// Descrição de um attachment de *render pass* (chave do cache).
    struct VulkanAttachmentKey: Hashable {
        var format: UInt32 = 0
        var samples: UInt32 = 0
        var load: UInt32 = 0
        var store: UInt32 = 0
        var initialLayout: UInt32 = 0
        var finalLayout: UInt32 = 0
    }

    /// Chave de cache de `VkRenderPass`: até 4 cores, os *resolves* delas e a profundidade, sem alocar.
    struct VulkanRenderPassKey: Hashable {
        static let maxColors = 4
        var colorCount: UInt8 = 0
        /// Bit `i`: a cor `i` tem *resolve*.
        var resolveMask: UInt8 = 0
        var hasDepth = false
        var c0 = VulkanAttachmentKey(), c1 = VulkanAttachmentKey()
        var c2 = VulkanAttachmentKey(), c3 = VulkanAttachmentKey()
        var r0 = VulkanAttachmentKey(), r1 = VulkanAttachmentKey()
        var r2 = VulkanAttachmentKey(), r3 = VulkanAttachmentKey()
        var depth = VulkanAttachmentKey()

        subscript(color index: Int) -> VulkanAttachmentKey {
            get {
                switch index {
                case 0: c0
                case 1: c1
                case 2: c2
                default: c3
                }
            }
            set {
                switch index {
                case 0: c0 = newValue
                case 1: c1 = newValue
                case 2: c2 = newValue
                default: c3 = newValue
                }
            }
        }

        subscript(resolve index: Int) -> VulkanAttachmentKey {
            get {
                switch index {
                case 0: r0
                case 1: r1
                case 2: r2
                default: r3
                }
            }
            set {
                switch index {
                case 0: r0 = newValue
                case 1: r1 = newValue
                case 2: r2 = newValue
                default: r3 = newValue
                }
            }
        }
    }

    /// Chave de cache de `VkFramebuffer`: o *render pass*, o tamanho e até 9 *views* (4 cores, 4 *resolves*,
    /// profundidade) como endereços.
    struct VulkanFramebufferKey: Hashable {
        var renderPass: UInt = 0
        var width: UInt32 = 0
        var height: UInt32 = 0
        var views: (UInt, UInt, UInt, UInt, UInt, UInt, UInt, UInt, UInt) = (0, 0, 0, 0, 0, 0, 0, 0, 0)

        subscript(view index: Int) -> UInt {
            get {
                withUnsafeBytes(of: views) {
                    $0.load(fromByteOffset: index * MemoryLayout<UInt>.stride, as: UInt.self)
                }
            }
            set {
                withUnsafeMutableBytes(of: &views) {
                    $0.storeBytes(
                        of: newValue, toByteOffset: index * MemoryLayout<UInt>.stride, as: UInt.self)
                }
            }
        }

        func contains(_ view: UInt) -> Bool {
            for index in 0..<9 where self[view: index] == view { return true }
            return false
        }

        static func == (a: Self, b: Self) -> Bool {
            guard a.renderPass == b.renderPass, a.width == b.width, a.height == b.height else { return false }
            for index in 0..<9 where a[view: index] != b[view: index] { return false }
            return true
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(renderPass)
            hasher.combine(width)
            hasher.combine(height)
            for index in 0..<9 { hasher.combine(self[view: index]) }
        }
    }

    extension CajuVulkanDevice {
        // MARK: Pipelines

        func makeRenderPipeline(_ d: CajuRenderPipelineDescriptor) throws(CajuRHIError)
            -> VulkanRenderPipeline
        {
            guard d.colorTargets.count <= capabilities.maxColorAttachments else {
                throw .invalidDescriptor(.tooManyAttachments)
            }
            guard !d.colorTargets.isEmpty || d.depth != nil else { throw .invalidDescriptor(.emptyUsage) }
            guard d.sampleCount == 1 || capabilities.sampleCounts.supports(d.sampleCount) else {
                throw .unsupported(.sampleCount(d.sampleCount))
            }
            for target in d.colorTargets where target.format.isDepth || target.format.isCompressed {
                throw .invalidDescriptor(.formatMismatch)
            }
            if let depth = d.depth, !depth.format.isDepth { throw .invalidDescriptor(.formatMismatch) }
            guard let vertex = shaders.value(for: d.vertex.module) else {
                throw .invalidHandle(index: d.vertex.module.index, generation: d.vertex.module.generation)
            }
            var fragment: VulkanShader?
            if let f = d.fragment {
                guard let record = shaders.value(for: f.module) else {
                    throw .invalidHandle(index: f.module.index, generation: f.module.generation)
                }
                fragment = record
            }

            // Layout: união dos *bindings* dos dois estágios, todos no set 0 do mapa do contrato.
            var merged: [(binding: UInt32, kind: CajuVulkanShaderReflection.DescriptorKind, stages: UInt32)] =
                []
            func add(_ bindings: [CajuVulkanShaderReflection.Binding], stage: VkShaderStageFlagBits)
                throws(CajuRHIError)
            {
                for b in bindings {
                    guard b.set == 0, b.count == 1, Int(b.binding) < CajuVulkanBindingMap.count else {
                        throw .invalidDescriptor(.exceedsDeviceLimit)
                    }
                    if let i = merged.firstIndex(where: { $0.binding == b.binding }) {
                        guard merged[i].kind == b.kind else { throw .invalidDescriptor(.incompatibleUsage) }
                        merged[i].stages |= stage.rawValue
                    } else {
                        merged.append((b.binding, b.kind, stage.rawValue))
                    }
                }
            }
            try add(vertex.bindings, stage: VK_SHADER_STAGE_VERTEX_BIT)
            if let fragment { try add(fragment.bindings, stage: VK_SHADER_STAGE_FRAGMENT_BIT) }
            // Sem VK_KHR_push_descriptor: plano B do ADR 0024 (pool de sets por submissão), ainda não feito.
            guard context.pushDescriptorSet != nil else { throw .backend(code: cajuVulkanNotImplementedCode) }
            // `maxPushDescriptors` é no mínimo 32 pela especificação.
            guard merged.count <= 32 else {
                throw .invalidDescriptor(.exceedsDeviceLimit)
            }

            var layoutBindings = merged.map { entry in
                VkDescriptorSetLayoutBinding(
                    binding: entry.binding, descriptorType: VkDescriptorType(entry.kind.rawValue),
                    descriptorCount: 1, stageFlags: VkShaderStageFlags(entry.stages), pImmutableSamplers: nil)
            }
            var setLayoutInfo = VkDescriptorSetLayoutCreateInfo()
            setLayoutInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
            setLayoutInfo.flags = VkDescriptorSetLayoutCreateFlags(
                VK_DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT_KHR.rawValue)
            setLayoutInfo.bindingCount = UInt32(layoutBindings.count)
            var createdSetLayout: VkDescriptorSetLayout?
            let setLayoutResult: VkResult = layoutBindings.withUnsafeMutableBufferPointer { bindings in
                setLayoutInfo.pBindings = UnsafePointer(bindings.baseAddress)
                return vkCreateDescriptorSetLayout(context.device, &setLayoutInfo, nil, &createdSetLayout)
            }
            try vkCheck(setLayoutResult)
            guard let setLayout = createdSetLayout else { throw .outOfMemory }

            var setLayoutOptional: VkDescriptorSetLayout? = setLayout
            var layoutInfo = VkPipelineLayoutCreateInfo()
            layoutInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
            layoutInfo.setLayoutCount = 1
            var createdLayout: VkPipelineLayout?
            let layoutResult: VkResult = withUnsafePointer(to: &setLayoutOptional) { setLayouts in
                layoutInfo.pSetLayouts = setLayouts
                return vkCreatePipelineLayout(context.device, &layoutInfo, nil, &createdLayout)
            }
            guard layoutResult == VK_SUCCESS, let layout = createdLayout else {
                vkDestroyDescriptorSetLayout(context.device, setLayout, nil)
                throw mapVkResult(layoutResult)
            }

            // Render pass compatível (formatos e amostras; com um subpasse, *resolves* não contam).
            var compatible = VulkanRenderPassKey()
            compatible.colorCount = UInt8(d.colorTargets.count)
            for (i, target) in d.colorTargets.enumerated() {
                compatible[color: i] = VulkanAttachmentKey(
                    format: target.format.vulkan.rawValue,
                    samples: vulkanSampleCount(d.sampleCount).rawValue,
                    load: VK_ATTACHMENT_LOAD_OP_DONT_CARE.rawValue,
                    store: VK_ATTACHMENT_STORE_OP_STORE.rawValue,
                    initialLayout: VK_IMAGE_LAYOUT_UNDEFINED.rawValue,
                    finalLayout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL.rawValue)
            }
            if let depth = d.depth {
                compatible.hasDepth = true
                compatible.depth = VulkanAttachmentKey(
                    format: depth.format.vulkan.rawValue, samples: vulkanSampleCount(d.sampleCount).rawValue,
                    load: VK_ATTACHMENT_LOAD_OP_DONT_CARE.rawValue,
                    store: VK_ATTACHMENT_STORE_OP_DONT_CARE.rawValue,
                    initialLayout: VK_IMAGE_LAYOUT_UNDEFINED.rawValue,
                    finalLayout: VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL.rawValue)
            }
            let renderPass: VkRenderPass
            do { renderPass = try self.renderPass(for: compatible) } catch {
                vkDestroyPipelineLayout(context.device, layout, nil)
                vkDestroyDescriptorSetLayout(context.device, setLayout, nil)
                throw error
            }

            let pipeline: VkPipeline
            do {
                pipeline = try createPipelineObject(
                    d, vertex: vertex.module, fragment: fragment?.module, layout: layout,
                    renderPass: renderPass)
            } catch {
                vkDestroyPipelineLayout(context.device, layout, nil)
                vkDestroyDescriptorSetLayout(context.device, setLayout, nil)
                throw error
            }
            return VulkanRenderPipeline(
                pipeline: pipeline, layout: layout, setLayout: setLayout,
                bindings: merged.map { ($0.binding, $0.kind) }, colorFormats: d.colorTargets.map(\.format),
                depthFormat: d.depth?.format, sampleCount: d.sampleCount)
        }

        private func createPipelineObject(
            _ d: CajuRenderPipelineDescriptor, vertex: VkShaderModule, fragment: VkShaderModule?,
            layout: VkPipelineLayout, renderPass: VkRenderPass
        ) throws(CajuRHIError) -> VkPipeline {
            var vertexBindings = d.vertexLayouts.map { l in
                VkVertexInputBindingDescription(
                    binding: UInt32(l.bufferIndex), stride: UInt32(l.stride),
                    inputRate: l.step == .perVertex
                        ? VK_VERTEX_INPUT_RATE_VERTEX : VK_VERTEX_INPUT_RATE_INSTANCE)
            }
            var vertexAttributes = d.vertexAttributes.map { a in
                VkVertexInputAttributeDescription(
                    location: UInt32(a.location), binding: UInt32(a.bufferIndex), format: a.format.vulkan,
                    offset: UInt32(a.offset))
            }
            var blendAttachments = d.colorTargets.map { target in
                var state = VkPipelineColorBlendAttachmentState()
                state.colorWriteMask =
                    target.writesAllChannels
                    ? VkColorComponentFlags(
                        VK_COLOR_COMPONENT_R_BIT.rawValue | VK_COLOR_COMPONENT_G_BIT.rawValue
                            | VK_COLOR_COMPONENT_B_BIT.rawValue | VK_COLOR_COMPONENT_A_BIT.rawValue) : 0
                if let blend = target.blend {
                    state.blendEnable = VkBool32(VK_TRUE)
                    state.srcColorBlendFactor = blend.sourceColor.vulkan
                    state.dstColorBlendFactor = blend.destinationColor.vulkan
                    state.colorBlendOp = blend.colorOperation.vulkan
                    state.srcAlphaBlendFactor = blend.sourceAlpha.vulkan
                    state.dstAlphaBlendFactor = blend.destinationAlpha.vulkan
                    state.alphaBlendOp = blend.alphaOperation.vulkan
                }
                return state
            }
            var dynamicStates = [VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR]

            var vertexInput = VkPipelineVertexInputStateCreateInfo()
            vertexInput.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO
            var inputAssembly = VkPipelineInputAssemblyStateCreateInfo()
            inputAssembly.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO
            inputAssembly.topology = d.topology.vulkan
            var viewport = VkPipelineViewportStateCreateInfo()
            viewport.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO
            viewport.viewportCount = 1
            viewport.scissorCount = 1
            var raster = VkPipelineRasterizationStateCreateInfo()
            raster.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO
            raster.polygonMode = VK_POLYGON_MODE_FILL
            raster.cullMode = d.cullMode.vulkan
            // O viewport invertido (altura negativa) inverte o sentido na janela: com ele, o sentido do NDC com
            // y para cima vale como no Metal, sem trocar `frontFace`.
            raster.frontFace =
                d.frontFace == .counterClockwise ? VK_FRONT_FACE_COUNTER_CLOCKWISE : VK_FRONT_FACE_CLOCKWISE
            raster.lineWidth = 1
            var multisample = VkPipelineMultisampleStateCreateInfo()
            multisample.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO
            multisample.rasterizationSamples = vulkanSampleCount(d.sampleCount)
            var depthStencil = VkPipelineDepthStencilStateCreateInfo()
            depthStencil.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO
            if let depth = d.depth {
                depthStencil.depthTestEnable = VkBool32(VK_TRUE)
                depthStencil.depthWriteEnable = depth.writesDepth ? VkBool32(VK_TRUE) : VkBool32(VK_FALSE)
                depthStencil.depthCompareOp = depth.compare.vulkan
            }
            var colorBlend = VkPipelineColorBlendStateCreateInfo()
            colorBlend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO
            var dynamic = VkPipelineDynamicStateCreateInfo()
            dynamic.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO

            var created: VkPipeline?
            let result: VkResult = d.vertex.entryPoint.withCString { vertexName in
                (d.fragment?.entryPoint ?? "main").withCString { fragmentName in
                    var stages = [VkPipelineShaderStageCreateInfo]()
                    var stage = VkPipelineShaderStageCreateInfo()
                    stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
                    stage.stage = VK_SHADER_STAGE_VERTEX_BIT
                    stage.module = vertex
                    stage.pName = vertexName
                    stages.append(stage)
                    if let fragment {
                        stage.stage = VK_SHADER_STAGE_FRAGMENT_BIT
                        stage.module = fragment
                        stage.pName = fragmentName
                        stages.append(stage)
                    }
                    return vertexBindings.withUnsafeMutableBufferPointer { vb in
                        vertexAttributes.withUnsafeMutableBufferPointer { va in
                            blendAttachments.withUnsafeMutableBufferPointer { ba in
                                dynamicStates.withUnsafeMutableBufferPointer { ds in
                                    stages.withUnsafeMutableBufferPointer { st in
                                        vertexInput.vertexBindingDescriptionCount = UInt32(vb.count)
                                        vertexInput.pVertexBindingDescriptions = UnsafePointer(vb.baseAddress)
                                        vertexInput.vertexAttributeDescriptionCount = UInt32(va.count)
                                        vertexInput.pVertexAttributeDescriptions = UnsafePointer(
                                            va.baseAddress)
                                        colorBlend.attachmentCount = UInt32(ba.count)
                                        colorBlend.pAttachments = UnsafePointer(ba.baseAddress)
                                        dynamic.dynamicStateCount = UInt32(ds.count)
                                        dynamic.pDynamicStates = UnsafePointer(ds.baseAddress)
                                        return createGraphicsPipeline(
                                            stages: st, vertexInput: &vertexInput,
                                            inputAssembly: &inputAssembly,
                                            viewport: &viewport, raster: &raster, multisample: &multisample,
                                            depthStencil: &depthStencil, colorBlend: &colorBlend,
                                            dynamic: &dynamic, layout: layout, renderPass: renderPass,
                                            out: &created)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            try vkCheck(result)
            guard let created else { throw .outOfMemory }
            return created
        }

        // swift-format-ignore: NeverUseImplicitlyUnwrappedOptionals
        private func createGraphicsPipeline(
            stages: UnsafeMutableBufferPointer<VkPipelineShaderStageCreateInfo>,
            vertexInput: inout VkPipelineVertexInputStateCreateInfo,
            inputAssembly: inout VkPipelineInputAssemblyStateCreateInfo,
            viewport: inout VkPipelineViewportStateCreateInfo,
            raster: inout VkPipelineRasterizationStateCreateInfo,
            multisample: inout VkPipelineMultisampleStateCreateInfo,
            depthStencil: inout VkPipelineDepthStencilStateCreateInfo,
            colorBlend: inout VkPipelineColorBlendStateCreateInfo,
            dynamic: inout VkPipelineDynamicStateCreateInfo,
            layout: VkPipelineLayout, renderPass: VkRenderPass, out: inout VkPipeline?
        ) -> VkResult {
            withUnsafePointer(to: &vertexInput) { vertexInput in
                withUnsafePointer(to: &inputAssembly) { inputAssembly in
                    withUnsafePointer(to: &viewport) { viewport in
                        withUnsafePointer(to: &raster) { raster in
                            withUnsafePointer(to: &multisample) { multisample in
                                withUnsafePointer(to: &depthStencil) { depthStencil in
                                    withUnsafePointer(to: &colorBlend) { colorBlend in
                                        withUnsafePointer(to: &dynamic) { dynamic in
                                            var info = VkGraphicsPipelineCreateInfo()
                                            info.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO
                                            info.stageCount = UInt32(stages.count)
                                            info.pStages = UnsafePointer(stages.baseAddress)
                                            info.pVertexInputState = vertexInput
                                            info.pInputAssemblyState = inputAssembly
                                            info.pViewportState = viewport
                                            info.pRasterizationState = raster
                                            info.pMultisampleState = multisample
                                            info.pDepthStencilState = depthStencil
                                            info.pColorBlendState = colorBlend
                                            info.pDynamicState = dynamic
                                            info.layout = layout
                                            info.renderPass = renderPass
                                            info.subpass = 0
                                            return vkCreateGraphicsPipelines(
                                                context.device, nil, 1, &info, nil, &out)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // MARK: Render pass e framebuffer em cache

        func renderPass(for key: VulkanRenderPassKey) throws(CajuRHIError) -> VkRenderPass {
            if let cached = renderPassCache[key] { return cached }
            var attachments: [VkAttachmentDescription] = []
            func description(_ a: VulkanAttachmentKey) -> VkAttachmentDescription {
                VkAttachmentDescription(
                    flags: 0, format: VkFormat(a.format), samples: VkSampleCountFlagBits(a.samples),
                    loadOp: VkAttachmentLoadOp(a.load), storeOp: VkAttachmentStoreOp(a.store),
                    stencilLoadOp: VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                    stencilStoreOp: VK_ATTACHMENT_STORE_OP_DONT_CARE,
                    initialLayout: VkImageLayout(a.initialLayout), finalLayout: VkImageLayout(a.finalLayout))
            }
            let unused = UInt32.max  // VK_ATTACHMENT_UNUSED
            var colorRefs: [VkAttachmentReference] = []
            var resolveRefs: [VkAttachmentReference] = []
            for i in 0..<Int(key.colorCount) {
                colorRefs.append(
                    VkAttachmentReference(
                        attachment: UInt32(attachments.count),
                        layout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL))
                attachments.append(description(key[color: i]))
            }
            for i in 0..<Int(key.colorCount) {
                if key.resolveMask & (1 << i) != 0 {
                    resolveRefs.append(
                        VkAttachmentReference(
                            attachment: UInt32(attachments.count),
                            layout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL))
                    attachments.append(description(key[resolve: i]))
                } else {
                    resolveRefs.append(
                        VkAttachmentReference(attachment: unused, layout: VK_IMAGE_LAYOUT_UNDEFINED))
                }
            }
            var depthRef = VkAttachmentReference(
                attachment: UInt32(attachments.count),
                layout: VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL)
            if key.hasDepth { attachments.append(description(key.depth)) }

            // Dependências externas conservadoras: o que veio antes (cópias, leituras, passes) termina antes
            // dos attachments, e o que vem depois enxerga as escritas (o contrato não tem barreiras).
            let graphicsStages =
                VK_PIPELINE_STAGE_VERTEX_INPUT_BIT.rawValue | VK_PIPELINE_STAGE_VERTEX_SHADER_BIT.rawValue
                | VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT.rawValue
                | VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT.rawValue
                | VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT.rawValue
                | VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT.rawValue
            let attachmentWrites =
                VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT.rawValue
                | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT.rawValue
            var dependencies = [
                VkSubpassDependency(
                    srcSubpass: UInt32.max, dstSubpass: 0,
                    srcStageMask: VkPipelineStageFlags(VK_PIPELINE_STAGE_ALL_COMMANDS_BIT.rawValue),
                    dstStageMask: VkPipelineStageFlags(graphicsStages),
                    srcAccessMask: VkAccessFlags(VK_ACCESS_MEMORY_WRITE_BIT.rawValue),
                    dstAccessMask: VkAccessFlags(
                        VK_ACCESS_COLOR_ATTACHMENT_READ_BIT.rawValue | attachmentWrites
                            | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT.rawValue
                            | VK_ACCESS_SHADER_READ_BIT.rawValue | VK_ACCESS_UNIFORM_READ_BIT.rawValue
                            | VK_ACCESS_VERTEX_ATTRIBUTE_READ_BIT.rawValue | VK_ACCESS_INDEX_READ_BIT.rawValue
                    ),
                    dependencyFlags: 0),
                VkSubpassDependency(
                    srcSubpass: 0, dstSubpass: UInt32.max,
                    srcStageMask: VkPipelineStageFlags(
                        VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT.rawValue
                            | VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT.rawValue),
                    dstStageMask: VkPipelineStageFlags(VK_PIPELINE_STAGE_ALL_COMMANDS_BIT.rawValue),
                    srcAccessMask: VkAccessFlags(attachmentWrites),
                    dstAccessMask: VkAccessFlags(
                        VK_ACCESS_MEMORY_READ_BIT.rawValue | VK_ACCESS_MEMORY_WRITE_BIT.rawValue),
                    dependencyFlags: 0),
            ]

            var created: VkRenderPass?
            let result: VkResult = attachments.withUnsafeMutableBufferPointer { att in
                colorRefs.withUnsafeMutableBufferPointer { color in
                    resolveRefs.withUnsafeMutableBufferPointer { resolve in
                        dependencies.withUnsafeMutableBufferPointer { deps in
                            withUnsafePointer(to: &depthRef) { depth in
                                var subpass = VkSubpassDescription()
                                subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS
                                subpass.colorAttachmentCount = UInt32(color.count)
                                subpass.pColorAttachments = UnsafePointer(color.baseAddress)
                                if key.resolveMask != 0 {
                                    subpass.pResolveAttachments = UnsafePointer(resolve.baseAddress)
                                }
                                if key.hasDepth { subpass.pDepthStencilAttachment = depth }
                                return withUnsafePointer(to: &subpass) { subpass in
                                    var info = VkRenderPassCreateInfo()
                                    info.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO
                                    info.attachmentCount = UInt32(att.count)
                                    info.pAttachments = UnsafePointer(att.baseAddress)
                                    info.subpassCount = 1
                                    info.pSubpasses = subpass
                                    info.dependencyCount = UInt32(deps.count)
                                    info.pDependencies = UnsafePointer(deps.baseAddress)
                                    return vkCreateRenderPass(context.device, &info, nil, &created)
                                }
                            }
                        }
                    }
                }
            }
            try vkCheck(result)
            guard let created else { throw .outOfMemory }
            renderPassCache[key] = created
            return created
        }

        func framebuffer(
            renderPass: VkRenderPass, views: UnsafeBufferPointer<VkImageView?>, width: UInt32, height: UInt32
        ) throws(CajuRHIError) -> VkFramebuffer {
            var key = VulkanFramebufferKey()
            key.renderPass = UInt(bitPattern: renderPass)
            key.width = width
            key.height = height
            for (i, view) in views.enumerated() { key[view: i] = UInt(bitPattern: view) }
            if let cached = framebufferCache[key] { return cached }
            var info = VkFramebufferCreateInfo()
            info.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO
            info.renderPass = renderPass
            info.attachmentCount = UInt32(views.count)
            info.pAttachments = views.baseAddress
            info.width = width
            info.height = height
            info.layers = 1
            var created: VkFramebuffer?
            try vkCheck(vkCreateFramebuffer(context.device, &info, nil, &created))
            guard let created else { throw .outOfMemory }
            framebufferCache[key] = created
            return created
        }

        /// Tira do cache (e destrói quando a GPU terminar) os framebuffers que usam as *views* da textura.
        func evictFramebuffers(using texture: VulkanTexture) {
            var views = [UInt(bitPattern: texture.view)]
            for view in texture.attachmentViews.values { views.append(UInt(bitPattern: view)) }
            for key in framebufferCache.keys where views.contains(where: key.contains) {
                if let framebuffer = framebufferCache.removeValue(forKey: key) {
                    retire(.framebuffer(framebuffer))
                }
            }
        }

        /// *View* 2D de um mip e camada para usar como attachment (a *view* principal cobre todos os mips).
        func attachmentView(_ texture: VulkanTexture, mipLevel: Int, slice: Int) throws(CajuRHIError)
            -> VkImageView
        {
            if texture.descriptor.mipLevels == 1, texture.layers == 1, texture.descriptor.dimension != .type3D
            {
                return texture.view
            }
            let key = mipLevel << 16 | slice
            if let view = texture.attachmentViews[key] { return view }
            var info = VkImageViewCreateInfo()
            info.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
            info.image = texture.image
            info.viewType = VK_IMAGE_VIEW_TYPE_2D
            info.format = texture.descriptor.format.vulkan
            info.subresourceRange = VkImageSubresourceRange(
                aspectMask: texture.descriptor.format.vulkanAspect, baseMipLevel: UInt32(mipLevel),
                levelCount: 1,
                baseArrayLayer: UInt32(slice), layerCount: 1)
            var view: VkImageView?
            try vkCheck(vkCreateImageView(context.device, &info, nil, &view))
            guard let view else { throw .outOfMemory }
            texture.attachmentViews[key] = view
            return view
        }
    }

    // MARK: Conversões de estado de pipeline

    extension CajuVertexFormat {
        var vulkan: VkFormat {
            switch self {
            case .float: VK_FORMAT_R32_SFLOAT
            case .float2: VK_FORMAT_R32G32_SFLOAT
            case .float3: VK_FORMAT_R32G32B32_SFLOAT
            case .float4: VK_FORMAT_R32G32B32A32_SFLOAT
            case .uint: VK_FORMAT_R32_UINT
            case .uint2: VK_FORMAT_R32G32_UINT
            case .uint3: VK_FORMAT_R32G32B32_UINT
            case .uint4: VK_FORMAT_R32G32B32A32_UINT
            case .unorm8x4: VK_FORMAT_R8G8B8A8_UNORM
            case .half2: VK_FORMAT_R16G16_SFLOAT
            case .half4: VK_FORMAT_R16G16B16A16_SFLOAT
            }
        }
    }

    extension CajuPrimitiveTopology {
        var vulkan: VkPrimitiveTopology {
            switch self {
            case .triangleList: VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST
            case .triangleStrip: VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP
            case .lineList: VK_PRIMITIVE_TOPOLOGY_LINE_LIST
            case .pointList: VK_PRIMITIVE_TOPOLOGY_POINT_LIST
            }
        }
    }

    extension CajuCullMode {
        var vulkan: VkCullModeFlags {
            switch self {
            case .none: 0
            case .front: VkCullModeFlags(VK_CULL_MODE_FRONT_BIT.rawValue)
            case .back: VkCullModeFlags(VK_CULL_MODE_BACK_BIT.rawValue)
            }
        }
    }

    extension CajuCompareFunction {
        var vulkan: VkCompareOp {
            switch self {
            case .never: VK_COMPARE_OP_NEVER
            case .less: VK_COMPARE_OP_LESS
            case .equal: VK_COMPARE_OP_EQUAL
            case .lessEqual: VK_COMPARE_OP_LESS_OR_EQUAL
            case .greater: VK_COMPARE_OP_GREATER
            case .notEqual: VK_COMPARE_OP_NOT_EQUAL
            case .greaterEqual: VK_COMPARE_OP_GREATER_OR_EQUAL
            case .always: VK_COMPARE_OP_ALWAYS
            }
        }
    }

    extension CajuBlendFactor {
        var vulkan: VkBlendFactor {
            switch self {
            case .zero: VK_BLEND_FACTOR_ZERO
            case .one: VK_BLEND_FACTOR_ONE
            case .sourceAlpha: VK_BLEND_FACTOR_SRC_ALPHA
            case .oneMinusSourceAlpha: VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
            case .destinationAlpha: VK_BLEND_FACTOR_DST_ALPHA
            case .oneMinusDestinationAlpha: VK_BLEND_FACTOR_ONE_MINUS_DST_ALPHA
            }
        }
    }

    extension CajuBlendOperation {
        var vulkan: VkBlendOp {
            switch self {
            case .add: VK_BLEND_OP_ADD
            case .subtract: VK_BLEND_OP_SUBTRACT
            case .reverseSubtract: VK_BLEND_OP_REVERSE_SUBTRACT
            case .min: VK_BLEND_OP_MIN
            case .max: VK_BLEND_OP_MAX
            }
        }
    }
#endif

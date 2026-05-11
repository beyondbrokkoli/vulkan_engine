local ffi = require("ffi")
local bit = require("bit")

local Descriptors = {}

function Descriptors.Init(vk, device, master_gpu_buffer)
    print("[DESCRIPTORS] Wiring Master VRAM Arena as a Unified SSBO...")

    -- ========================================================
    -- 1. Single Binding for the Entire Memory Arena
    -- ========================================================
    local ssboBinding = ffi.new("VkDescriptorSetLayoutBinding[1]")
    ssboBinding[0].binding = 0
    ssboBinding[0].descriptorType = 7 -- VK_DESCRIPTOR_TYPE_STORAGE_BUFFER
    ssboBinding[0].descriptorCount = 1
    
    -- Accessible in both Compute (Simulation) and Vertex (Rendering)
    local STAGE_COMPUTE = 32
    local STAGE_VERTEX = 1
    ssboBinding[0].stageFlags = bit.bor(STAGE_COMPUTE, STAGE_VERTEX) 

    local layoutInfo = ffi.new("VkDescriptorSetLayoutCreateInfo")
    ffi.fill(layoutInfo, ffi.sizeof(layoutInfo))
    layoutInfo.sType = 32
    layoutInfo.bindingCount = 1
    layoutInfo.pBindings = ssboBinding

    local pLayout = ffi.new("VkDescriptorSetLayout[1]")
    assert(vk.vkCreateDescriptorSetLayout(device, layoutInfo, nil, pLayout) == 0, "FATAL: Failed to create Descriptor Layout")
    local unifiedDescriptorSetLayout = pLayout[0]

    -- ========================================================
    -- 2. Push Constants: 64 BYTES (The Matrix Router)
    -- ========================================================
    -- Used to pass the dynamically sliced offsets (X, Y, Z indices) 
    -- and engine state (Delta Time, etc.) to the shaders.
    local pushRange = ffi.new("VkPushConstantRange[1]")
    ffi.fill(pushRange, ffi.sizeof(pushRange))
    pushRange[0].stageFlags = bit.bor(STAGE_COMPUTE, STAGE_VERTEX)
    pushRange[0].offset = 0
    pushRange[0].size = 64

    -- ========================================================
    -- 3. Pipeline Layout
    -- ========================================================
    local computeLayoutInfo = ffi.new("VkPipelineLayoutCreateInfo")
    ffi.fill(computeLayoutInfo, ffi.sizeof(computeLayoutInfo))
    computeLayoutInfo.sType = 30
    computeLayoutInfo.setLayoutCount = 1
    computeLayoutInfo.pSetLayouts = ffi.new("VkDescriptorSetLayout[1]", {unifiedDescriptorSetLayout})
    computeLayoutInfo.pushConstantRangeCount = 1
    computeLayoutInfo.pPushConstantRanges = pushRange

    local pPipeLayout = ffi.new("VkPipelineLayout[1]")
    assert(vk.vkCreatePipelineLayout(device, computeLayoutInfo, nil, pPipeLayout) == 0)
    local unifiedPipelineLayout = pPipeLayout[0]

    -- ========================================================
    -- 4. Descriptor Pool
    -- ========================================================
    local poolSize = ffi.new("VkDescriptorPoolSize[1]")
    ffi.fill(poolSize, ffi.sizeof(poolSize))
    poolSize[0].type = 7
    poolSize[0].descriptorCount = 1

    local poolInfo = ffi.new("VkDescriptorPoolCreateInfo")
    ffi.fill(poolInfo, ffi.sizeof(poolInfo))
    poolInfo.sType = 33
    poolInfo.poolSizeCount = 1
    poolInfo.pPoolSizes = poolSize
    poolInfo.maxSets = 1

    local pPool = ffi.new("VkDescriptorPool[1]")
    assert(vk.vkCreateDescriptorPool(device, poolInfo, nil, pPool) == 0)
    local descriptorPool = pPool[0]

    -- ========================================================
    -- 5. Allocate the Singular Descriptor Set
    -- ========================================================
    local allocSetInfo = ffi.new("VkDescriptorSetAllocateInfo")
    ffi.fill(allocSetInfo, ffi.sizeof(allocSetInfo))
    allocSetInfo.sType = 34
    allocSetInfo.descriptorPool = descriptorPool
    allocSetInfo.descriptorSetCount = 1
    allocSetInfo.pSetLayouts = ffi.new("VkDescriptorSetLayout[1]", {unifiedDescriptorSetLayout})

    local pSet = ffi.new("VkDescriptorSet[1]")
    assert(vk.vkAllocateDescriptorSets(device, allocSetInfo, pSet) == 0)

    -- ========================================================
    -- 6. Bind the Entire 256MB VRAM Block
    -- ========================================================
    local VK_WHOLE_SIZE = ffi.cast("uint64_t", -1)

    local bufInfo = ffi.new("VkDescriptorBufferInfo[1]")
    bufInfo[0].buffer = master_gpu_buffer
    bufInfo[0].offset = 0
    bufInfo[0].range = VK_WHOLE_SIZE

    local write = ffi.new("VkWriteDescriptorSet[1]")
    ffi.fill(write, ffi.sizeof(write))
    write[0].sType = 35
    write[0].dstSet = pSet[0]
    write[0].dstBinding = 0
    write[0].descriptorType = 7
    write[0].descriptorCount = 1
    write[0].pBufferInfo = bufInfo

    vk.vkUpdateDescriptorSets(device, 1, write, 0, nil)

    print("[DESCRIPTORS] Unified Memory Matrix successfully bound!")

    return {
        setLayout = unifiedDescriptorSetLayout,
        pipelineLayout = unifiedPipelineLayout,
        pool = descriptorPool,
        set0 = pSet[0]
    }
end

function Descriptors.Destroy(vk, device, desc_state)
    print("[TEARDOWN] Deconstructing Descriptors...")
    if not desc_state then return end

    if desc_state.pool ~= nil then vk.vkDestroyDescriptorPool(device, desc_state.pool, nil) end
    if desc_state.setLayout ~= nil then vk.vkDestroyDescriptorSetLayout(device, desc_state.setLayout, nil) end
    if desc_state.pipelineLayout ~= nil then vk.vkDestroyPipelineLayout(device, desc_state.pipelineLayout, nil) end
end

return Descriptors

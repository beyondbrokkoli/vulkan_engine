local ffi = require("ffi")

local Renderer = {}

-- Define the C-struct so Lua can allocate it!
ffi.cdef[[
    typedef struct {
        VkDevice device;
        VkSwapchainKHR swapchain;
        VkQueue queue;
        VkCommandBuffer* cmd_buffers;
        VkSemaphore image_available;
        VkSemaphore render_finished;
        VkFence in_flight;
    } RenderContext;
]]

function Renderer.InitMinimalCyan(vk, vk_state, sc_state)
    print("[RENDERER] Bootstrapping Cyan Clear Pipeline...")

    -- 1. Create Command Pool
    local poolInfo = ffi.new("VkCommandPoolCreateInfo", {
        sType = 39, -- VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
        flags = 2,  -- VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT
        queueFamilyIndex = vk_state.qIndex
    })
    local pPool = ffi.new("VkCommandPool[1]")
    assert(vk.vkCreateCommandPool(vk_state.device, poolInfo, nil, pPool) == 0)
    local commandPool = pPool[0]

    -- 2. Allocate Command Buffers
    local allocInfo = ffi.new("VkCommandBufferAllocateInfo", {
        sType = 40, -- VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
        commandPool = commandPool,
        level = 0,  -- PRIMARY
        commandBufferCount = sc_state.imageCount
    })
    local commandBuffers = ffi.new("VkCommandBuffer[?]", sc_state.imageCount)
    assert(vk.vkAllocateCommandBuffers(vk_state.device, allocInfo, commandBuffers) == 0)

    -- 3. Record the Cyan Clear Command
    for i = 0, sc_state.imageCount - 1 do
        local beginInfo = ffi.new("VkCommandBufferBeginInfo", { sType = 42 })
        vk.vkBeginCommandBuffer(commandBuffers[i], beginInfo)

        -- Transition Image: UNDEFINED -> TRANSFER_DST_OPTIMAL
        local barrier = ffi.new("VkImageMemoryBarrier", {
            sType = 45,
            oldLayout = 0, newLayout = 7, -- UNDEFINED to TRANSFER_DST
            srcQueueFamilyIndex = 4294967295, dstQueueFamilyIndex = 4294967295,
            image = sc_state.images[i],
            subresourceRange = { aspectMask = 1, levelCount = 1, layerCount = 1 },
            srcAccessMask = 0, dstAccessMask = 4096 -- TRANSFER_WRITE
        })
        vk.vkCmdPipelineBarrier(commandBuffers[i], 8192, 4096, 0, 0, nil, 0, nil, 1, barrier)

        -- CLEAR TO CYAN! (R=0, G=1, B=1)
        local clearColor = ffi.new("VkClearColorValue")
        clearColor.float32[0] = 0.0; clearColor.float32[1] = 1.0; 
        clearColor.float32[2] = 1.0; clearColor.float32[3] = 1.0;
        
        local range = ffi.new("VkImageSubresourceRange[1]", {{ aspectMask = 1, levelCount = 1, layerCount = 1 }})
        vk.vkCmdClearColorImage(commandBuffers[i], sc_state.images[i], 7, clearColor, 1, range)

        -- Transition Image: TRANSFER_DST_OPTIMAL -> PRESENT_SRC_KHR
        barrier.oldLayout = 7; barrier.newLayout = 1000001002
        barrier.srcAccessMask = 4096; barrier.dstAccessMask = 0
        vk.vkCmdPipelineBarrier(commandBuffers[i], 4096, 8192, 0, 0, nil, 0, nil, 1, barrier)

        vk.vkEndCommandBuffer(commandBuffers[i])
    end

    -- 4. Create Sync Objects
    local semInfo = ffi.new("VkSemaphoreCreateInfo", { sType = 9 })
    local fenceInfo = ffi.new("VkFenceCreateInfo", { sType = 8, flags = 1 }) -- SIGNALED_BIT
    
    local pImgSem = ffi.new("VkSemaphore[1]"); vk.vkCreateSemaphore(vk_state.device, semInfo, nil, pImgSem)
    local pRndSem = ffi.new("VkSemaphore[1]"); vk.vkCreateSemaphore(vk_state.device, semInfo, nil, pRndSem)
    local pFence = ffi.new("VkFence[1]"); vk.vkCreateFence(vk_state.device, fenceInfo, nil, pFence)

    -- 5. Build the FFI Struct for C
    local ctx = ffi.new("RenderContext")
    ctx.device = vk_state.device
    ctx.swapchain = sc_state.handle
    ctx.queue = vk_state.queue
    ctx.cmd_buffers = commandBuffers
    ctx.image_available = pImgSem[0]
    ctx.render_finished = pRndSem[0]
    ctx.in_flight = pFence[0]

    return ctx
end

return Renderer

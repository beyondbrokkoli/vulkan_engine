local ffi = require("ffi")
local bit = require("bit")
local vulkan_core = require("vulkan_core")
local memory = require("memory")
local swapchain_core = require("swapchain")
local descriptors = require("descriptors")
local compute = require("compute_pipeline")
local graphics = require("graphics_pipeline")

ffi.cdef[[
int vibe_get_is_running();
int vibe_publish_and_get_next_buffer();
void vibe_trigger_shutdown();
void vibe_mark_lua_finished();
const char** vibe_get_glfw_extensions(uint32_t* count);
void vibe_publish_vk_instance(void* instance);
void* vibe_get_vk_surface();
void vibe_publish_render_context(void* ctx);
void vibe_get_window_size(int* width, int* height);

typedef struct {
    void* device;
    void* swapchain;
    void* queue;
    void* cmd_buffers;
    void* image_available;
    void* render_finished;
    void* in_flight;
} RenderContext;

typedef struct {
    uint32_t pos_x_idx;
    uint32_t pos_y_idx;
    uint32_t pos_z_idx;
    uint32_t particle_count;
    float dt;
    uint32_t pad[11]; // Total 64 Bytes
} SwarmPushConstants;

typedef struct {
    uint32_t vertexCount;
    uint32_t instanceCount;
    uint32_t firstVertex;
    uint32_t firstInstance;
} VkDrawIndirectCommand;

void vkCmdDrawIndirect(void* commandBuffer, void* buffer, uint64_t offset, uint32_t drawCount, uint32_t stride);
void vkCmdFillBuffer(void* commandBuffer, void* dstBuffer, uint64_t dstOffset, uint64_t size, uint32_t data);
]]

print("[LUA VM] Entering Lock-Free Horizon.")
local active_coroutines = {}
local function start_coroutine(func) table.insert(active_coroutines, coroutine.create(func)) end
local current_write_idx = 2

local function vulkan_bootstrap_coroutine()
    print("[LUA CO] Bootstrapping Vulkan...")
    local vk_state = vulkan_core.create_instance()
    if vk_state.instance == nil then
        ffi.C.vibe_trigger_shutdown()
        return
    end

    ffi.C.vibe_publish_vk_instance(vk_state.instance)
    local surface_ptr = nil
    while true do
        surface_ptr = ffi.C.vibe_get_vk_surface()
        if surface_ptr ~= nil then break end
        coroutine.yield()
    end

    vulkan_core.finalize_device_and_swapchain(vk_state, surface_ptr)
    local vk = vk_state.vk
    local device = vk_state.device

    -- Memory Matrix
    local UNIVERSE_SIZE = 256 * 1024 * 1024
    local PARTICLE_COUNT = 15000000

    memory.AllocateSoA("uint8_t", UNIVERSE_SIZE, {"MASTER_CPU_BLOCK"})
    local cpu_arena = memory.CreateArena(memory.AVX_Arrays["MASTER_CPU_BLOCK"], UNIVERSE_SIZE)
    local pos_x = cpu_arena:slice("float", PARTICLE_COUNT)
    local pos_y = cpu_arena:slice("float", PARTICLE_COUNT)
    local pos_z = cpu_arena:slice("float", PARTICLE_COUNT)

    -- 32 = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT
    -- 128 = VK_BUFFER_USAGE_VERTEX_BUFFER_BIT (Technically optional now, but safe to keep)
    local usage_flags = bit.bor(32, 128)
    memory.CreateHostVisibleBuffer("MASTER_GPU_BLOCK", "uint8_t", UNIVERSE_SIZE, usage_flags, vk_state)
    local gpu_arena = memory.CreateArena(memory.Mapped["MASTER_GPU_BLOCK"], UNIVERSE_SIZE)
    local gpu_pos_x = gpu_arena:slice("float", PARTICLE_COUNT)
    local gpu_pos_y = gpu_arena:slice("float", PARTICLE_COUNT)
    local gpu_pos_z = gpu_arena:slice("float", PARTICLE_COUNT)

    -- FFI Pointer Arithmetic -> Float Array Indices
    local base_addr = ffi.cast("uintptr_t", memory.Mapped["MASTER_GPU_BLOCK"])
    local x_idx = tonumber(ffi.cast("uintptr_t", gpu_pos_x) - base_addr) / 4
    local y_idx = tonumber(ffi.cast("uintptr_t", gpu_pos_y) - base_addr) / 4
    local z_idx = tonumber(ffi.cast("uintptr_t", gpu_pos_z) - base_addr) / 4

    local pushConstants = ffi.new("SwarmPushConstants", {
        pos_x_idx = x_idx, pos_y_idx = y_idx, pos_z_idx = z_idx, 
        particle_count = PARTICLE_COUNT, dt = 0.016
    })

    local pWidth = ffi.new("int[1]")
    local pHeight = ffi.new("int[1]")
    ffi.C.vibe_get_window_size(pWidth, pHeight)
    local sc_state = swapchain_core.Init(vk, vk_state, pWidth[0], pHeight[0])

    -- Setup Pipelines & Descriptors
    local desc_state = descriptors.Init(vk, device, memory.Buffers["MASTER_GPU_BLOCK"])
    local comp_state = compute.Init(vk, device, desc_state.pipelineLayout)
    local gfx_state = graphics.Init(vk, vk_state, pWidth[0], pHeight[0], desc_state.pipelineLayout, sc_state.format)

    -- Command Pool & Synchronization
    local cmdPoolInfo = ffi.new("VkCommandPoolCreateInfo", { sType = 39, flags = 2, queueFamilyIndex = vk_state.qIndex })
    local pCmdPool = ffi.new("VkCommandPool[1]")
    vk.vkCreateCommandPool(device, cmdPoolInfo, nil, pCmdPool)

    local allocInfo = ffi.new("VkCommandBufferAllocateInfo", {
        sType = 40, commandPool = pCmdPool[0], level = 0, commandBufferCount = sc_state.imageCount
    })
    local cmdBuffers = ffi.new("VkCommandBuffer[?]", sc_state.imageCount)
    vk.vkAllocateCommandBuffers(device, allocInfo, cmdBuffers)

    local semInfo = ffi.new("VkSemaphoreCreateInfo", { sType = 9 })
    local fenInfo = ffi.new("VkFenceCreateInfo", { sType = 8, flags = 1 }) -- Signaled
    local pImgAvail = ffi.new("VkSemaphore[1]")
    local pRendFinish = ffi.new("VkSemaphore[1]")
    local pInFlight = ffi.new("VkFence[1]")
    vk.vkCreateSemaphore(device, semInfo, nil, pImgAvail)
    vk.vkCreateSemaphore(device, semInfo, nil, pRendFinish)
    vk.vkCreateFence(device, fenInfo, nil, pInFlight)

    print("[LUA CO] Orchestrating Dual-State Indirect Command Streams...")

    -- Allocate Indirect Arguments within the Mega-Buffer
    local indirect_args = gpu_arena:slice("VkDrawIndirectCommand", sc_state.imageCount)
    local indirect_base_offset = tonumber(ffi.cast("uintptr_t", indirect_args) - base_addr)

    for i = 0, sc_state.imageCount - 1 do
        local cmd = cmdBuffers[i]
        local beginInfo = ffi.new("VkCommandBufferBeginInfo", { sType = 42 })
        vk.vkBeginCommandBuffer(cmd, beginInfo)
    
       -- We calculate ping-pong offsets for this specific frame context
        -- Frame A reads X, writes Y. Frame B reads Y, writes X.
        local read_offset  = (i % 2 == 0) and x_idx or y_idx
        local write_offset = (i % 2 == 0) and y_idx or x_idx
    
        pushConstants.pos_x_idx = read_offset
        pushConstants.pos_y_idx = write_offset
    
        -- ========================================================
        -- PHASE 1: TEMPORAL GRID / COMMAND CLEAR
        -- ========================================================
        -- Zero out the indirect command block for this specific frame
        local current_indirect_offset = indirect_base_offset + (i * ffi.sizeof("VkDrawIndirectCommand"))
        vk.vkCmdFillBuffer(cmd, memory.Buffers["MASTER_GPU_BLOCK"], current_indirect_offset, ffi.sizeof("VkDrawIndirectCommand"), 0)

        -- Memory Barrier: Fill -> Compute Write
        local fillBarrier = ffi.new("VkMemoryBarrier", { 
            sType = 46, 
            srcAccessMask = 4096, -- VK_ACCESS_TRANSFER_WRITE_BIT
            dstAccessMask = 32    -- VK_ACCESS_SHADER_WRITE_BIT
        })
        vk.vkCmdPipelineBarrier(cmd, 4096, 2048, 0, 1, ffi.new("VkMemoryBarrier[1]", {fillBarrier}), 0, nil, 0, nil)

       -- ========================================================
        -- PHASE 2: COMPUTE & SWARM DISPATCH
        -- ========================================================
        vk.vkCmdBindPipeline(cmd, 32, comp_state.pipeline)
        local pSet = ffi.new("VkDescriptorSet[1]", {desc_state.set0})
        vk.vkCmdBindDescriptorSets(cmd, 32, desc_state.pipelineLayout, 0, 1, pSet, 0, nil)
        vk.vkCmdPushConstants(cmd, desc_state.pipelineLayout, 33, 0, 64, pushConstants)
    
       local groupCount = math.ceil(PARTICLE_COUNT / 256)
        vk.vkCmdDispatch(cmd, groupCount, 1, 1)

        -- Memory Barrier: Compute Write -> Vertex Read & Indirect Read
        local memBarrier = ffi.new("VkMemoryBarrier", { 
            sType = 46, 
            srcAccessMask = 32,   -- VK_ACCESS_SHADER_WRITE_BIT
            dstAccessMask = 131136 -- VK_ACCESS_SHADER_READ_BIT (64) | VK_ACCESS_INDIRECT_COMMAND_READ_BIT (131072)
        })
        vk.vkCmdPipelineBarrier(cmd, 2048, 264, 0, 1, ffi.new("VkMemoryBarrier[1]", {memBarrier}), 0, nil, 0, nil)

        -- ========================================================
        -- PHASE 3: DYNAMIC GRAPHICS PIPELINE (INDIRECT)
        -- ========================================================
        local imgBarriers = ffi.new("VkImageMemoryBarrier[2]")
        -- Color Attachment Layout Transition
        imgBarriers[0].sType = 45
        imgBarriers[0].oldLayout = 0
        imgBarriers[0].newLayout = 1000044000 -- VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
        imgBarriers[0].srcQueueFamilyIndex = 4294967295
        imgBarriers[0].dstQueueFamilyIndex = 4294967295
        imgBarriers[0].image = sc_state.images[i]
        imgBarriers[0].subresourceRange = { aspectMask = 1, baseMipLevel = 0, levelCount = 1, baseArrayLayer = 0, layerCount = 1 }
        imgBarriers[0].srcAccessMask = 0
        imgBarriers[0].dstAccessMask = 256
    
        -- Depth Attachment Layout Transition
        imgBarriers[1].sType = 45
        imgBarriers[1].oldLayout = 0
        imgBarriers[1].newLayout = 3 -- VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
        imgBarriers[1].srcQueueFamilyIndex = 4294967295
        imgBarriers[1].dstQueueFamilyIndex = 4294967295
        imgBarriers[1].image = gfx_state.depthImage
        imgBarriers[1].subresourceRange = { aspectMask = 2, baseMipLevel = 0, levelCount = 1, baseArrayLayer = 0, layerCount = 1 }
        imgBarriers[1].srcAccessMask = 0
        imgBarriers[1].dstAccessMask = 1024

        vk.vkCmdPipelineBarrier(cmd, 1, 1024, 0, 0, nil, 0, nil, 2, imgBarriers)

        local colorAttachment = ffi.new("VkRenderingAttachmentInfo", {
            sType = 1000044000, 
            imageView = sc_state.imageViews[i], 
           imageLayout = 1000044000,
            loadOp = 0, storeOp = 0,
            clearValue = { color = { float32 = { 0.01, 0.01, 0.02, 1.0 } } }
        })

        local depthAttachment = ffi.new("VkRenderingAttachmentInfo", {
            sType = 1000044000, 
            imageView = gfx_state.depthImageView, 
            imageLayout = 3,
            loadOp = 0, storeOp = 1,
            clearValue = { depthStencil = { depth = 0.0, stencil = 0 } }
        })

        local renderingInfo = ffi.new("VkRenderingInfo", {
            sType = 1000044001,
            renderArea = { offset = {0,0}, extent = sc_state.extent },
            layerCount = 1,
            colorAttachmentCount = 1, pColorAttachments = ffi.new("VkRenderingAttachmentInfo[1]", {colorAttachment}),
            pDepthAttachment = ffi.new("VkRenderingAttachmentInfo[1]", {depthAttachment})
       })

        vk.vkCmdBeginRenderingKHR(cmd, ffi.new("VkRenderingInfo[1]", {renderingInfo}))
        vk.vkCmdBindPipeline(cmd, 0, gfx_state.pipeline)

        -- Rebind descriptor for the Vertex stage to access the unified SSBO
        vk.vkCmdBindDescriptorSets(cmd, 0, desc_state.pipelineLayout, 0, 1, pSet, 0, nil)

        -- Swap read/write visually for the fragment shader. 
        -- The vertex shader MUST read from what Compute just wrote (write_offset)
        local renderPush = ffi.new("SwarmPushConstants", pushConstants)
        renderPush.pos_x_idx = write_offset
        vk.vkCmdPushConstants(cmd, desc_state.pipelineLayout, 33, 0, 64, renderPush)

        local viewport = ffi.new("VkViewport", { x=0, y=0, width=pWidth[0], height=pHeight[0], minDepth=0, maxDepth=1 })
        local scissor = ffi.new("VkRect2D", { offset={0,0}, extent=sc_state.extent })
        vk.vkCmdSetViewport(cmd, 0, 1, ffi.new("VkViewport[1]", {viewport}))
        vk.vkCmdSetScissor(cmd, 0, 1, ffi.new("VkRect2D[1]", {scissor}))

        -- STRICT RULE: No vkCmdBindVertexBuffers. Native Indirect routing via Mega-Buffer.
        vk.vkCmdDrawIndirect(cmd, memory.Buffers["MASTER_GPU_BLOCK"], current_indirect_offset, 1, ffi.sizeof("VkDrawIndirectCommand"))

        vk.vkCmdEndRenderingKHR(cmd)

        local imgBarrierToPresent = ffi.new("VkImageMemoryBarrier", {
            sType = 45, 
            oldLayout = 1000044000, 
            newLayout = 1000001002, -- VK_IMAGE_LAYOUT_PRESENT_SRC_KHR
            srcQueueFamilyIndex = 4294967295, dstQueueFamilyIndex = 4294967295,
            image = sc_state.images[i],
            subresourceRange = { aspectMask = 1, baseMipLevel = 0, levelCount = 1, baseArrayLayer = 0, layerCount = 1 },
            srcAccessMask = 256, 
            dstAccessMask = 0
        })

        vk.vkCmdPipelineBarrier(cmd, 1024, 8192, 0, 0, nil, 0, nil, 1, ffi.new("VkImageMemoryBarrier[1]", {imgBarrierToPresent}))
        vk.vkEndCommandBuffer(cmd)
    end

    -- Publish to C via Lock-Free Mailbox
    local renderCtx = ffi.new("RenderContext", {
        device = device, swapchain = sc_state.handle, queue = vk_state.queue,
        cmd_buffers = cmdBuffers,
        image_available = pImgAvail[0], render_finished = pRendFinish[0], in_flight = pInFlight[0]
    })
    ffi.C.vibe_publish_render_context(renderCtx)

    print("[LUA CO] Context Dispatched! Entering Idle Generator Loop...")
    while ffi.C.vibe_get_is_running() == 1 do
        current_write_idx = ffi.C.vibe_publish_and_get_next_buffer()
        coroutine.yield()
    end

    print("[LUA CO] Engine Shutdown Detected. Commencing Teardown...")
    vk.vkDeviceWaitIdle(device)
    vk.vkDestroySemaphore(device, pImgAvail[0], nil)
    vk.vkDestroySemaphore(device, pRendFinish[0], nil)
    vk.vkDestroyFence(device, pInFlight[0], nil)
    vk.vkDestroyCommandPool(device, pCmdPool[0], nil)
    
    graphics.Destroy(vk, vk_state, gfx_state)
    compute.Destroy(vk, vk_state, comp_state)
    descriptors.Destroy(vk, device, desc_state)
    swapchain_core.Destroy(vk, vk_state, sc_state)
    vulkan_core.Destroy(vk_state)
end

start_coroutine(vulkan_bootstrap_coroutine)

while ffi.C.vibe_get_is_running() == 1 do
    for i = #active_coroutines, 1, -1 do
        local co = active_coroutines[i]
        if coroutine.status(co) ~= "dead" then
            local success, err = coroutine.resume(co)
            assert(success, "FATAL: COROUTINE CRASHED: " .. tostring(err))
        else
            table.remove(active_coroutines, i)
        end
    end
end
print("[LUA VM] Exiting gracefully...")
ffi.C.vibe_mark_lua_finished()

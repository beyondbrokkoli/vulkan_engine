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

    print("[LUA CO] Recording Multi-buffer Command Streams...")
    for i = 0, sc_state.imageCount - 1 do
        local cmd = cmdBuffers[i]
        local beginInfo = ffi.new("VkCommandBufferBeginInfo", { sType = 42 })
        vk.vkBeginCommandBuffer(cmd, beginInfo)

        -- 1. Dispatch Compute
        vk.vkCmdBindPipeline(cmd, 32, comp_state.pipeline)
        local pSet = ffi.new("VkDescriptorSet[1]", {desc_state.set0})
        vk.vkCmdBindDescriptorSets(cmd, 32, desc_state.pipelineLayout, 0, 1, pSet, 0, nil)
        vk.vkCmdPushConstants(cmd, desc_state.pipelineLayout, 33, 0, 64, pushConstants)
        
        local groupCount = math.ceil(PARTICLE_COUNT / 256)
        vk.vkCmdDispatch(cmd, groupCount, 1, 1)

        -- 2. SSBO Memory Barrier (Compute write -> Vertex read)
        local memBarrier = ffi.new("VkMemoryBarrier", { sType = 46, srcAccessMask = 32, dstAccessMask = 64 })
        vk.vkCmdPipelineBarrier(cmd, 2048, 8, 0, 1, memBarrier, 0, nil, 0, nil)

        -- 3. Transition Color Image AND Depth Image Layouts
        local imgBarriers = ffi.new("VkImageMemoryBarrier[2]")
        
        imgBarriers[0].sType = 45; imgBarriers[0].oldLayout = 0; imgBarriers[0].newLayout = 1000044000 -- COLOR_ATTACHMENT_OPTIMAL
        imgBarriers[0].srcQueueFamilyIndex = 4294967295; imgBarriers[0].dstQueueFamilyIndex = 4294967295
        imgBarriers[0].image = sc_state.images[i]
        imgBarriers[0].subresourceRange = { aspectMask = 1, baseMipLevel = 0, levelCount = 1, baseArrayLayer = 0, layerCount = 1 }
        imgBarriers[0].srcAccessMask = 0; imgBarriers[0].dstAccessMask = 256

        imgBarriers[1].sType = 45; imgBarriers[1].oldLayout = 0; imgBarriers[1].newLayout = 3 -- DEPTH_STENCIL_ATTACHMENT_OPTIMAL
        imgBarriers[1].srcQueueFamilyIndex = 4294967295; imgBarriers[1].dstQueueFamilyIndex = 4294967295
        imgBarriers[1].image = gfx_state.depthImage
        imgBarriers[1].subresourceRange = { aspectMask = 2, baseMipLevel = 0, levelCount = 1, baseArrayLayer = 0, layerCount = 1 }
        imgBarriers[1].srcAccessMask = 0; imgBarriers[1].dstAccessMask = 1024 -- DEPTH_STENCIL_ATTACHMENT_WRITE_BIT

        vk.vkCmdPipelineBarrier(cmd, 1, 1024, 0, 0, nil, 0, nil, 2, imgBarriers)

        -- 4. Dynamic Rendering with Depth Attached
        local colorAttachment = ffi.new("VkRenderingAttachmentInfo", {
            sType = 1000044000, imageView = sc_state.imageViews[i], imageLayout = 1000044000,
            loadOp = 0, storeOp = 0, -- VK_ATTACHMENT_LOAD_OP_CLEAR / STORE
            clearValue = { color = { float32 = { 0.02, 0.02, 0.02, 1.0 } } }
        })

        local depthAttachment = ffi.new("VkRenderingAttachmentInfo", {
            sType = 1000044000, imageView = gfx_state.depthImageView, imageLayout = 3, -- DEPTH_STENCIL_ATTACHMENT_OPTIMAL
            loadOp = 0, storeOp = 1, -- VK_ATTACHMENT_LOAD_OP_CLEAR / DONT_CARE
            clearValue = { depthStencil = { depth = 0.0, stencil = 0 } } -- Reverse-Z Clear (0.0)
        })

        local renderingInfo = ffi.new("VkRenderingInfo", {
            sType = 1000044001,
            renderArea = { offset = {0,0}, extent = sc_state.extent },
            layerCount = 1, 
            colorAttachmentCount = 1, pColorAttachments = colorAttachment,
            pDepthAttachment = depthAttachment
        })

        vk.vkCmdBeginRenderingKHR(cmd, renderingInfo)
        
        vk.vkCmdBindPipeline(cmd, 0, gfx_state.pipeline)
        -- The single unified SSBO is bound exactly once here for the vertex shader
        vk.vkCmdBindDescriptorSets(cmd, 0, desc_state.pipelineLayout, 0, 1, pSet, 0, nil)
        vk.vkCmdPushConstants(cmd, desc_state.pipelineLayout, 33, 0, 64, pushConstants)

        -- Dynamic Viewport & Scissor
        local viewport = ffi.new("VkViewport", { x=0, y=0, width=pWidth[0], height=pHeight[0], minDepth=0, maxDepth=1 })
        local scissor = ffi.new("VkRect2D", { offset={0,0}, extent=sc_state.extent })
        vk.vkCmdSetViewport(cmd, 0, 1, ffi.new("VkViewport[1]", {viewport}))
        vk.vkCmdSetScissor(cmd, 0, 1, ffi.new("VkRect2D[1]", {scissor}))

        -- The Empty Draw Call (Instanceless, Bufferless)
        vk.vkCmdDraw(cmd, PARTICLE_COUNT, 1, 0, 0)
        
        vk.vkCmdEndRenderingKHR(cmd)

        -- 5. Transition Image for Presentation
        local imgBarrierToPresent = ffi.new("VkImageMemoryBarrier", {
            sType = 45, oldLayout = 1000044000, newLayout = 1000001002,
            srcQueueFamilyIndex = 4294967295, dstQueueFamilyIndex = 4294967295,
            image = sc_state.images[i],
            subresourceRange = { aspectMask = 1, baseMipLevel = 0, levelCount = 1, baseArrayLayer = 0, layerCount = 1 },
            srcAccessMask = 256, dstAccessMask = 0
        })
        vk.vkCmdPipelineBarrier(cmd, 1024, 8192, 0, 0, nil, 0, nil, 1, imgBarrierToPresent)

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

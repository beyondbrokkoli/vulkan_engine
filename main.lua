local ffi = require("ffi")
local vulkan_core = require("vulkan_core")

ffi.cdef[[
    int vibe_get_is_running();
    int vibe_publish_and_get_next_buffer();
    void vibe_trigger_shutdown();
    void vibe_mark_lua_finished();

    // The Handshake Hooks
    const char** vibe_get_glfw_extensions(uint32_t* count);
    void vibe_publish_vk_instance(void* instance);
    void* vibe_get_vk_surface();
    void vibe_publish_render_context(void* ctx);
    void vibe_get_window_size(int* width, int* height);
]]

print("[LUA VM] Entering Lock-Free Horizon.")
local active_coroutines = {}
local function start_coroutine(func)
    table.insert(active_coroutines, coroutine.create(func))
end

local current_write_idx = 2

local function vulkan_bootstrap_coroutine()
    print("[LUA CO] Bootstrapping Vulkan...")
    local vk_state = vulkan_core.create_instance()
    if vk_state.instance == nil then
        print("[LUA FATAL] Failed to create real Vulkan Instance!")
        ffi.C.vibe_trigger_shutdown()
        return
    end

    print("[LUA CO] Publishing REAL VkInstance to C. Waiting for Window Surface...")
    ffi.C.vibe_publish_vk_instance(vk_state.instance)

    local surface_ptr = nil
    while true do
        surface_ptr = ffi.C.vibe_get_vk_surface()
        if surface_ptr ~= nil then break end
        coroutine.yield()
    end

    print("[LUA CO] Window Surface Acquired! Resuming Pipeline Generation...")
    vulkan_core.finalize_device_and_swapchain(vk_state, surface_ptr)

    -- ========================================================
    -- MEMORY ARENAS (The 512MB Slice)
    -- ========================================================
    local memory = require("memory")
    local UNIVERSE_SIZE = 256 * 1024 * 1024
    
    memory.AllocateSoA("uint8_t", UNIVERSE_SIZE, {"MASTER_CPU_BLOCK"})
    local cpu_arena = memory.CreateArena(memory.AVX_Arrays["MASTER_CPU_BLOCK"], UNIVERSE_SIZE)
    local pos_x = cpu_arena:slice("float", 15000000)
    local pos_y = cpu_arena:slice("float", 15000000)
    local pos_z = cpu_arena:slice("float", 15000000)

    local usage_flags = bit.bor(29, 128) -- STORAGE | VERTEX
    memory.CreateHostVisibleBuffer("MASTER_GPU_BLOCK", "uint8_t", UNIVERSE_SIZE, usage_flags, vk_state)
    local gpu_arena = memory.CreateArena(memory.Mapped["MASTER_GPU_BLOCK"], UNIVERSE_SIZE)
    local gpu_pos_x = gpu_arena:slice("float", 15000000)
    local gpu_pos_y = gpu_arena:slice("float", 15000000)
    local gpu_pos_z = gpu_arena:slice("float", 15000000)

    -- ========================================================
    -- SWAPCHAIN INIT
    -- ========================================================
    local swapchain_core = require("swapchain")
    local pWidth = ffi.new("int[1]"); local pHeight = ffi.new("int[1]")
    ffi.C.vibe_get_window_size(pWidth, pHeight)
    local sc_state = swapchain_core.Init(vk_state.vk, vk_state, pWidth[0], pHeight[0])

    -- ========================================================
    -- [ THE PIPELINE MATRIX PLACEHOLDERS ]
    -- ========================================================
    print("[LUA CO] Preparing to build Graphics/Compute Pipelines...")
    
    -- TODO 1: local desc_state = require("descriptors").Init(vk_state, gpu_pos_x, gpu_pos_y, ...)
    -- TODO 2: local compute_state = require("compute_pipeline").Init(vk_state, desc_state)
    -- TODO 3: local gfx_state = require("graphics_pipeline").Init(vk_state, sc_state)
    -- TODO 4: local render_ctx = RecordCommandBuffers(vk_state, sc_state, compute_state, gfx_state)
    -- TODO 5: ffi.C.vibe_publish_render_context(render_ctx)

    -- ========================================================
    -- MAIN ENGINE LOOP
    -- ========================================================
    print("[LUA CO] Pipeline Generated! Entering Main Render Loop...")
    local i = 0
    while ffi.C.vibe_get_is_running() == 1 do
        i = i + 1
        current_write_idx = ffi.C.vibe_publish_and_get_next_buffer()
        coroutine.yield()
    end

    -- ========================================================
    -- TEARDOWN PROTOCOL
    -- ========================================================
    print("[LUA CO] Engine Shutdown Detected. Commencing Teardown...")
    -- TODO: desc_state:Destroy(), compute_state:Destroy(), gfx_state:Destroy()
    swapchain_core.Destroy(vk_state.vk, vk_state, sc_state)
    vulkan_core.Destroy(vk_state)
    print("[LUA CO] Vulkan Destroyed. Coroutine Terminating.")
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

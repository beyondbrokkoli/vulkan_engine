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
]]

print("[LUA VM] Entering Lock-Free Horizon.")

local active_coroutines = {}
local function start_coroutine(func)
    table.insert(active_coroutines, coroutine.create(func))
end

local current_write_idx = 2

local function vulkan_bootstrap_coroutine()
    print("[LUA CO] Bootstrapping Vulkan...")

    -- 1. Run your actual Vulkan Instance Creation!
    -- (Make sure your vulkan_core.lua has a function that just creates the instance)
    local vk_state = vulkan_core.create_instance()

    if vk_state.instance == nil then
        print("[LUA FATAL] Failed to create real Vulkan Instance!")
        ffi.C.vibe_trigger_shutdown()
        return
    end

    -- 2. Publish the REAL Instance to C
    print("[LUA CO] Publishing REAL VkInstance to C. Waiting for Window Surface...")
    ffi.C.vibe_publish_vk_instance(vk_state.instance)

    -- 3. Yield until C gives us the surface back
    local surface_ptr = nil
    while true do
        surface_ptr = ffi.C.vibe_get_vk_surface()
        if surface_ptr ~= nil then
            break
        end
        coroutine.yield()
    end

    print("[LUA CO] Window Surface Acquired! Resuming Pipeline Generation...")

    -- 4. Now finish the Vulkan setup (Physical Device, Logical Device, Swapchain)
    -- passing the surface_ptr into your module
    vulkan_core.finalize_device_and_swapchain(vk_state, surface_ptr)

    print("[LUA CO] Pipeline Generated! Entering Main Render Loop...")

    local i = 0
    while ffi.C.vibe_get_is_running() == 1 do
        i = i + 1
        current_write_idx = ffi.C.vibe_publish_and_get_next_buffer()

        -- [OPTIONAL] Uncomment this if you want the automated 200-frame shutdown testing back.
        -- Otherwise, the engine runs until you click the OS Window 'X' button!
        -- if i == 200 then
        --     print("\n[LUA CO] Reached 200 iterations! Triggering C-Side Teardown...")
        --     ffi.C.vibe_trigger_shutdown()
        -- end

        coroutine.yield()
    end

    -- [CRITICAL FIX] Clean up Vulkan objects when the engine shuts down!
    vulkan_core.Destroy(vk_state)
    print("[LUA CO] Engine Shutdown Detected. Vulkan Destroyed. Coroutine Terminating.")
end

-- Kick off the bootstrap
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

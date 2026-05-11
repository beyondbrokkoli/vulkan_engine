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

-- ==========================================
-- THE KUNG FOO VULKAN INIT COROUTINE
-- ==========================================
local function vulkan_bootstrap_coroutine()
    print("[LUA CO] Bootstrapping Vulkan...")

    -- 1. Get GLFW Extensions from C natively
    local pCount = ffi.new("uint32_t[1]")
    local glfwExtensions = ffi.C.vibe_get_glfw_extensions(pCount)
    print(string.format("[LUA CO] Received %d GLFW Extensions from C.", pCount[0]))

    -- [Pretend we ran the rest of vulkan_core.lua to create the VkInstance here]
    -- For demonstration, we simulate creating a fake instance pointer
    local fake_instance = ffi.cast("void*", 0xDEADBEEF) 

    -- 2. Publish the Instance back to C
    print("[LUA CO] Publishing VkInstance to C. Waiting for Window Surface...")
    ffi.C.vibe_publish_vk_instance(fake_instance)

    -- 3. THE MAGIC YIELD LOOP
    -- Instead of burning CPU, we politely yield until C delivers the surface.
    local surface_ptr = nil
    while true do
        surface_ptr = ffi.C.vibe_get_vk_surface()
        if surface_ptr ~= nil then
            break 
        end
        coroutine.yield() -- Return control to Overlord Loop
    end

    print("[LUA CO] Window Surface Acquired! Resuming Pipeline Generation...")
    
    -- Now you can pass surface_ptr to your device/swapchain creation logic
    -- e.g., vk.vkGetPhysicalDeviceSurfaceSupportKHR(...)
    
    -- Move into standard logic
    local i = 0
    while ffi.C.vibe_get_is_running() == 1 do
        i = i + 1
        current_write_idx = ffi.C.vibe_publish_and_get_next_buffer()
        if i == 200 then
            print("\n[LUA CO] Reached 200 iterations! Triggering C-Side Teardown...")
            ffi.C.vibe_trigger_shutdown()
        end
        coroutine.yield()
    end
end

-- Kick off the bootstrap
start_coroutine(vulkan_bootstrap_coroutine)

-- ==========================================
-- THE OVERLORD LOOP
-- ==========================================
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

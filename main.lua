local ffi = require("ffi")
local vulkan_core = require("vulkan_core")

ffi.cdef[[
    int vibe_get_is_running();
    void vibe_trigger_shutdown();
    void vibe_mark_lua_finished();
    const char** vibe_get_glfw_extensions(uint32_t* count);
    void vibe_publish_vk_instance(void* instance);
    void* vibe_get_vk_surface();
]]

print("[LUA VM] Entering Lock-Free Horizon.")

local active_coroutines = {}
local function start_coroutine(func) table.insert(active_coroutines, coroutine.create(func)) end

local function phase_one_bootstrap()
    print("[LUA CO] Bootstrapping Vulkan Instance...")
    local vk_state = vulkan_core.create_instance()
    
    if not vk_state or not vk_state.instance then
        ffi.C.vibe_trigger_shutdown()
        return
    end
    
    ffi.C.vibe_publish_vk_instance(vk_state.instance)
    
    print("[LUA CO] Waiting for C-Core Surface Allocation...")
    local surface_ptr = nil
    while ffi.C.vibe_get_is_running() == 1 do
        surface_ptr = ffi.C.vibe_get_vk_surface()
        if surface_ptr ~= nil then
            print(string.format("[LUA CO] Surface Acquired: %s", tostring(surface_ptr)))
            break
        end
        coroutine.yield()
    end
    
    -- Idle until C-Core triggers shutdown
    while ffi.C.vibe_get_is_running() == 1 do
        coroutine.yield()
    end
    
    print("[LUA CO] Teardown Detected. Destroying Instance...")
    vulkan_core.Destroy(vk_state)
end

start_coroutine(phase_one_bootstrap)

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

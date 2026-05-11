local ffi = require("ffi")
local bit = require("bit")

if ffi.os == "Windows" then
    ffi.cdef[[
        void* _aligned_malloc(size_t size, size_t alignment);
        void _aligned_free(void* ptr);
    ]]
else
    ffi.cdef[[
        void* aligned_alloc(size_t alignment, size_t size);
        void free(void* ptr);
    ]]
end

local Memory = {
    Buffers = {},
    DeviceMemory = {},
    Mapped = {},
    AVX_Arrays = {}
}

local function FindSmartBufferMemory(vk, physicalDevice, typeFilter)
    local memProperties = ffi.new("VkPhysicalDeviceMemoryProperties")
    vk.vkGetPhysicalDeviceMemoryProperties(physicalDevice, memProperties)

    local rebarFlags = bit.bor(1, 2, 4) -- DEVICE_LOCAL | HOST_VISIBLE | HOST_COHERENT
    for i = 0, memProperties.memoryTypeCount - 1 do
        if bit.band(typeFilter, bit.lshift(1, i)) ~= 0 and bit.band(memProperties.memoryTypes[i].propertyFlags, rebarFlags) == rebarFlags then
            print("[MEMORY] ReBAR Supported! Streaming directly to VRAM.")
            return i
        end
    end

    local stdFlags = bit.bor(2, 4) -- HOST_VISIBLE | HOST_COHERENT
    for i = 0, memProperties.memoryTypeCount - 1 do
        if bit.band(typeFilter, bit.lshift(1, i)) ~= 0 and bit.band(memProperties.memoryTypes[i].propertyFlags, stdFlags) == stdFlags then
            print("[MEMORY] ReBAR NOT found. Falling back to System RAM.")
            return i
        end
    end
    error("FATAL: Failed to find suitable buffer memory!")
end

function Memory.CreateHostVisibleBuffer(name, cdef_type, element_count, usage_flags, core_state)
    local vk = core_state.vk -- Pull the library dynamically!
    local byte_size = ffi.sizeof(cdef_type) * element_count

    local bufInfo = ffi.new("VkBufferCreateInfo", {
        sType = 12, size = byte_size, usage = usage_flags, sharingMode = 0
    })

    local pBuffer = ffi.new("VkBuffer[1]")
    assert(vk.vkCreateBuffer(core_state.device, bufInfo, nil, pBuffer) == 0, "FATAL: vkCreateBuffer failed")
    Memory.Buffers[name] = pBuffer[0]

    local memReqs = ffi.new("VkMemoryRequirements")
    vk.vkGetBufferMemoryRequirements(core_state.device, Memory.Buffers[name], memReqs)

    local allocInfo = ffi.new("VkMemoryAllocateInfo", {
        sType = 5,
        allocationSize = memReqs.size,
        memoryTypeIndex = FindSmartBufferMemory(vk, core_state.physicalDevice, memReqs.memoryTypeBits)
    })

    local pMemory = ffi.new("VkDeviceMemory[1]")
    assert(vk.vkAllocateMemory(core_state.device, allocInfo, nil, pMemory) == 0)
    Memory.DeviceMemory[name] = pMemory[0]
    assert(vk.vkBindBufferMemory(core_state.device, Memory.Buffers[name], Memory.DeviceMemory[name], 0) == 0)

    local ppData = ffi.new("void*[1]")
    assert(vk.vkMapMemory(core_state.device, Memory.DeviceMemory[name], 0, byte_size, 0, ppData) == 0)

    Memory.Mapped[name] = ffi.cast(cdef_type .. "*", ppData[0])
    print("[MEMORY] Allocated & Mapped VRAM Buffer: " .. name)
end

function Memory.AllocateSoA(type_str, count, names)
    local base_type = string.gsub(type_str, "%[.-%]", "")
    local byte_size = ffi.sizeof(base_type) * count

    for i = 1, #names do
        local raw_ptr = ffi.os == "Windows" and ffi.C._aligned_malloc(byte_size, 64) or ffi.C.aligned_alloc(64, byte_size)
        assert(raw_ptr ~= nil, "FATAL: C-Allocator failed to provide aligned memory!")
        Memory.AVX_Arrays[names[i]] = ffi.cast(base_type .. "*", raw_ptr)
        print(string.format("[MEMORY] Allocated Pure AVX2 SoA: %s (%.2f MB)", names[i], byte_size / (1024*1024)))
    end
end

function Memory.FreeSoA(names)
    for i = 1, #names do
        local ptr = Memory.AVX_Arrays[names[i]]
        if ptr then
            if ffi.os == "Windows" then ffi.C._aligned_free(ptr) else ffi.C.free(ptr) end
            Memory.AVX_Arrays[names[i]] = nil
        end
    end
end

-- THE ARENA SLICER (Zero-Overhead Sub-Allocation with Strict AVX2 Alignment)
function Memory.CreateArena(base_ptr, total_bytes)
    local arena = {
        base = ffi.cast("uint8_t*", base_ptr),
        offset = 0,
        capacity = total_bytes
    }

    function arena:slice(cdef_type, element_count)
        local base_bytes = ffi.sizeof(cdef_type) * element_count

        -- [CRITICAL FIX] Snap to 64-byte alignment for AVX2 / Cache Lines
        local padding = 0
        if base_bytes % 64 ~= 0 then
            padding = 64 - (base_bytes % 64)
        end
        local aligned_bytes = base_bytes + padding

        if self.offset + aligned_bytes > self.capacity then
            error(string.format("FATAL: Arena Out of Memory! Requested: %d (Aligned to %d). Remaining: %d.",
                  base_bytes, aligned_bytes, self.capacity - self.offset))
        end

        local ptr = ffi.cast(cdef_type .. "*", self.base + self.offset)
        self.offset = self.offset + aligned_bytes

        return ptr
    end

    function arena:get_utilization()
        return (self.offset / self.capacity) * 100.0
    end

    return arena
end

return Memory

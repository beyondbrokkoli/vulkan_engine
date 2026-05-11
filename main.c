#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdalign.h>

// --- VULKAN & GLFW ---
#define GLFW_INCLUDE_VULKAN
#include <GLFW/glfw3.h>

#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#ifdef _WIN32
#define EXPORT __declspec(dllexport)
#include <windows.h>
#define SLEEP_MS(ms) Sleep(ms)
typedef HANDLE vmath_thread_t; 
#define THREAD_FUNC DWORD WINAPI
#define THREAD_RETURN_VAL 0
static vmath_thread_t vmath_thread_start(DWORD (WINAPI *func)(LPVOID), void* arg) { 
    return CreateThread(NULL, 0, func, arg, 0, NULL); 
} 
static void vmath_thread_join(vmath_thread_t thread) { 
    WaitForSingleObject(thread, INFINITE); 
    CloseHandle(thread); 
} 
#else
#define EXPORT __attribute__((visibility("default")))
#include <pthread.h>
#include <unistd.h>
#define SLEEP_MS(ms) usleep((ms) * 1000)
typedef pthread_t vmath_thread_t; 
#define THREAD_FUNC void*
#define THREAD_RETURN_VAL NULL
static vmath_thread_t vmath_thread_start(void* (*func)(void*), void* arg) { 
    pthread_t thread; 
    pthread_create(&thread, NULL, func, arg); 
    return thread; 
} 
static void vmath_thread_join(vmath_thread_t thread) { 
    pthread_join(thread, NULL); 
} 
#endif
// --- VULKAN RENDER CONTEXT ---
// This is the struct Lua will fill and pass to C
typedef struct {
    VkDevice device;
    VkSwapchainKHR swapchain;
    VkQueue queue;
    VkCommandBuffer* cmd_buffers; // Array of pre-recorded command buffers
    VkSemaphore image_available;
    VkSemaphore render_finished;
    VkFence in_flight;
} RenderContext;

// Add this into your IPC_Mailbox struct:
// _Atomic(void*) vk_render_context;

EXPORT void vibe_publish_render_context(void* ctx) {
    atomic_store_explicit(&g_engine.mailbox.vk_render_context, ctx, memory_order_release);
}
// --- UPGRADED LOCK-FREE MAILBOX ---
typedef struct { 
    alignas(64) _Atomic int ready_index; 
    _Atomic int is_running; 
    _Atomic int lua_finished; 
    // New: Opaque pointers for the Vulkan Handshake
    _Atomic(void*) vk_instance; 
    _Atomic(void*) vk_surface;
    _Atomic(void*) vk_render_context;
} IPC_Mailbox; 

typedef struct { 
    IPC_Mailbox mailbox; 
    int render_index; 
    int write_index; 
} EngineState; 

static EngineState g_engine; 

// --- ENGINE STATE FFI ---
EXPORT int vibe_get_is_running() { 
    return atomic_load_explicit(&g_engine.mailbox.is_running, memory_order_relaxed); 
} 

EXPORT int vibe_publish_and_get_next_buffer() { 
    g_engine.write_index = atomic_exchange_explicit( 
        &g_engine.mailbox.ready_index, g_engine.write_index, memory_order_release 
    ); 
    return g_engine.write_index; 
} 

EXPORT void vibe_trigger_shutdown() { 
    atomic_store_explicit(&g_engine.mailbox.is_running, 0, memory_order_release); 
} 

EXPORT void vibe_mark_lua_finished() { 
    atomic_store_explicit(&g_engine.mailbox.lua_finished, 1, memory_order_release); 
} 

// --- VULKAN HANDSHAKE FFI ---
EXPORT const char** vibe_get_glfw_extensions(uint32_t* count) {
    return glfwGetRequiredInstanceExtensions(count);
}

EXPORT void vibe_publish_vk_instance(void* instance) {
    atomic_store_explicit(&g_engine.mailbox.vk_instance, instance, memory_order_release);
}

EXPORT void* vibe_get_vk_surface() {
    return atomic_load_explicit(&g_engine.mailbox.vk_surface, memory_order_acquire);
}
EXPORT void vibe_publish_render_context(void* ctx) {
    atomic_store_explicit(&g_engine.mailbox.vk_render_context, ctx, memory_order_release);
}
// --- VULKAN VALIDATION LAYER ENFORCER ---
VkDebugUtilsMessengerEXT g_debugMessenger = VK_NULL_HANDLE;

static VKAPI_ATTR VkBool32 VKAPI_CALL vulkan_debug_callback(
    VkDebugUtilsMessageSeverityFlagBitsEXT messageSeverity,
    VkDebugUtilsMessageTypeFlagsEXT messageType,
    const VkDebugUtilsMessengerCallbackDataEXT* pCallbackData,
    void* pUserData) {

    // Ignore INFO and VERBOSE spam
    if (messageSeverity < VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) {
        return VK_FALSE;
    }

    printf("\n[VULKAN LAYER ENFORCER]\nSEVERITY: %d\nMESSAGE: %s\n\n",
           messageSeverity, pCallbackData->pMessage);
    fflush(stdout);

    return VK_FALSE;
}

EXPORT void vibe_inject_validation_layers(void* instance_ptr) {
    VkInstance instance = (VkInstance)instance_ptr;
    
    VkDebugUtilsMessengerCreateInfoEXT createInfo = {0};
    createInfo.sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT;
    createInfo.messageSeverity = VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT | 
                                 VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | 
                                 VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
    createInfo.messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | 
                             VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT | 
                             VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
    createInfo.pfnUserCallback = vulkan_debug_callback;

    // We must load this function dynamically because it's an extension
    PFN_vkCreateDebugUtilsMessengerEXT func = 
        (PFN_vkCreateDebugUtilsMessengerEXT) glfwGetInstanceProcAddress(instance, "vkCreateDebugUtilsMessengerEXT");
    
    if (func != NULL) {
        func(instance, &createInfo, NULL, &g_debugMessenger);
        printf("[C-CORE] Validation Layer Enforcer Injected Successfully!\n");
    } else {
        printf("[C-FATAL] Failed to setup debug messenger (VK_EXT_debug_utils not found).\n");
    }
}
// Inside main.c
EXPORT void vibe_get_window_size(int* width, int* height) {
    // In a real scenario, you'd query glfwGetFramebufferSize(window, width, height)
    // For now, we enforce the engine's hardcoded lock
    *width = 1280;
    *height = 720;
}
// --- INITIALIZATION ---
void vibe_init_mailbox() { 
    atomic_init(&g_engine.mailbox.ready_index, 0); 
    atomic_init(&g_engine.mailbox.is_running, 1); 
    atomic_init(&g_engine.mailbox.lua_finished, 0); 
    atomic_init(&g_engine.mailbox.vk_instance, NULL);
    atomic_init(&g_engine.mailbox.vk_surface, NULL);
    g_engine.render_index = 1; 
    g_engine.write_index = 2; 
} 

void vibe_acquire_newest_frame() { 
    g_engine.render_index = atomic_exchange_explicit( 
        &g_engine.mailbox.ready_index, g_engine.render_index, memory_order_acquire 
    ); 
} 

// --- LUA THREAD ---
THREAD_FUNC lua_co_overlord_loop(void* arg) { 
    printf("[LUA-OS-THREAD] Booting Lua VM...\n"); 
    lua_State* L = luaL_newstate(); 
    luaL_openlibs(L); 
    if (luaL_dofile(L, "main.lua") != LUA_OK) { 
        printf("\n[LUA FATAL ERROR] %s\n", lua_tostring(L, -1)); 
    } 
    lua_close(L); 
    printf("[LUA-OS-THREAD] VM Destroyed.\n"); 
    return THREAD_RETURN_VAL; 
} 

// --- MAIN C-THREAD ---
int main(int argc, char** argv) { 
    printf("[C-CORE] Booting Minified Concurrent Pipeline...\n"); 
    
    // 1. Initialize GLFW strictly for window management
    if (!glfwInit()) return -1;
    glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
    glfwWindowHint(GLFW_RESIZABLE, GLFW_FALSE);
    GLFWwindow* window = glfwCreateWindow(1280, 720, "Lock-Free Swarm", NULL, NULL);

    vibe_init_mailbox(); 
    vmath_thread_t lua_thread = vmath_thread_start(lua_co_overlord_loop, NULL); 
    
    int frame_count = 0; 
    bool surface_created = false;

    // 2. Main Render & Event Loop
    while (vibe_get_is_running()) { 
        glfwPollEvents();
        if (glfwWindowShouldClose(window)) {
            vibe_trigger_shutdown();
        }

        // --- THE HANDSHAKE CHECK ---
        if (!surface_created) {
            void* instance = atomic_load_explicit(&g_engine.mailbox.vk_instance, memory_order_acquire);
            if (instance != NULL) {
                VkSurfaceKHR surface;
                if (glfwCreateWindowSurface((VkInstance)instance, window, NULL, &surface) == VK_SUCCESS) {
                    atomic_store_explicit(&g_engine.mailbox.vk_surface, (void*)surface, memory_order_release);
                    surface_created = true;
                    printf("[C-CORE] Window Surface Created & Published to Lua!\n");
                } else {
                    printf("[C-FATAL] Failed to create Vulkan Surface.\n");
                    vibe_trigger_shutdown();
                }
            }
        }

        vibe_acquire_newest_frame();

        // Lock-Free Render Execution
        void* ctx_ptr = atomic_load_explicit(&g_engine.mailbox.vk_render_context, memory_order_acquire);
        if (ctx_ptr != NULL) {
            RenderContext* ctx = (RenderContext*)ctx_ptr;

            // 1. Wait for the GPU to finish the last frame
            vkWaitForFences(ctx->device, 1, &ctx->in_flight, VK_TRUE, UINT64_MAX);
            vkResetFences(ctx->device, 1, &ctx->in_flight);

            // 2. Grab the next available image from the Swapchain
            uint32_t imageIndex;
            vkAcquireNextImageKHR(ctx->device, ctx->swapchain, UINT64_MAX, ctx->image_available, VK_NULL_HANDLE, &imageIndex);

            // 3. Submit Lua's pre-recorded Cyan Command Buffer
            VkSubmitInfo submitInfo = {0};
            submitInfo.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;

            VkSemaphore waitSemaphores[] = {ctx->image_available};
            VkPipelineStageFlags waitStages[] = {VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};
            submitInfo.waitSemaphoreCount = 1;
            submitInfo.pWaitSemaphores = waitSemaphores;
            submitInfo.pWaitDstStageMask = waitStages;

            submitInfo.commandBufferCount = 1;
            submitInfo.pCommandBuffers = &ctx->cmd_buffers[imageIndex]; // The magic index!

            VkSemaphore signalSemaphores[] = {ctx->render_finished};
            submitInfo.signalSemaphoreCount = 1;
            submitInfo.pSignalSemaphores = signalSemaphores;

            vkQueueSubmit(ctx->queue, 1, &submitInfo, ctx->in_flight);

            // 4. Push to Monitor (V-Sync)
            VkPresentInfoKHR presentInfo = {0};
            presentInfo.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
            presentInfo.waitSemaphoreCount = 1;
            presentInfo.pWaitSemaphores = signalSemaphores;

            VkSwapchainKHR swapchains[] = {ctx->swapchain};
            presentInfo.swapchainCount = 1;
            presentInfo.pSwapchains = swapchains;
            presentInfo.pImageIndices = &imageIndex;

            vkQueuePresentKHR(ctx->queue, &presentInfo);

            // We successfully rendered! (No SLEEP_MS needed here, vkQueuePresentKHR blocks for VSync)
        } else {
            SLEEP_MS(16); // Throttle CPU while waiting for Lua to build the Render Context
        }
    }
    printf("\n[C-CORE] Shutdown triggered. Waiting for Lua handshake...\n"); 
    while (atomic_load_explicit(&g_engine.mailbox.lua_finished, memory_order_acquire) == 0) { 
        SLEEP_MS(1); 
    } 
    
    vmath_thread_join(lua_thread); 
    glfwDestroyWindow(window);
    glfwTerminate();
    printf("[C-CORE] Clean Exit.\n"); 
    return 0; 
}

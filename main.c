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

// --- UPGRADED LOCK-FREE MAILBOX ---
typedef struct { 
    alignas(64) _Atomic int ready_index; 
    _Atomic int is_running; 
    _Atomic int lua_finished; 
    // New: Opaque pointers for the Vulkan Handshake
    _Atomic(void*) vk_instance; 
    _Atomic(void*) vk_surface;  
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
        
        if (frame_count % 30 == 0) { 
            // printf("[C-RENDER] Drawing from Buffer Index: %d\n", g_engine.render_index); 
        } 
        frame_count++; 
        SLEEP_MS(16); // Throttle until Vulkan V-Sync takes over
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

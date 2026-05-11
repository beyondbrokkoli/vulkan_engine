#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdalign.h>

// 1. Inject Vulkan and GLFW
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

// --- LOCK-FREE MAILBOX (Untouched Titanium Foundation) ---
typedef struct {
    alignas(64) _Atomic int ready_index;
    _Atomic int is_running;
    _Atomic int lua_finished;
} IPC_Mailbox;

typedef struct {
    IPC_Mailbox mailbox;
    int render_index;
    int write_index;
} EngineState;

static EngineState g_engine;

EXPORT int vibe_get_is_running() {
    return atomic_load_explicit(&g_engine.mailbox.is_running, memory_order_relaxed);
}

EXPORT int vibe_publish_and_get_next_buffer() {
    g_engine.write_index = atomic_exchange_explicit(
        &g_engine.mailbox.ready_index,
        g_engine.write_index,
        memory_order_release
    );
    return g_engine.write_index;
}

EXPORT void vibe_trigger_shutdown() {
    atomic_store_explicit(&g_engine.mailbox.is_running, 0, memory_order_release);
}

EXPORT void vibe_mark_lua_finished() {
    atomic_store_explicit(&g_engine.mailbox.lua_finished, 1, memory_order_release);
}

void vibe_init_mailbox() {
    atomic_init(&g_engine.mailbox.ready_index, 0);
    atomic_init(&g_engine.mailbox.is_running, 1);
    atomic_init(&g_engine.mailbox.lua_finished, 0);
    g_engine.render_index = 1;
    g_engine.write_index = 2;
}

void vibe_acquire_newest_frame() {
    g_engine.render_index = atomic_exchange_explicit(
        &g_engine.mailbox.ready_index,
        g_engine.render_index,
        memory_order_acquire
    );
}

// --- LUA OVERLORD THREAD ---
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

// --- VULKAN & GLFW SUBSYSTEM ---
GLFWwindow* init_glfw_window(int width, int height, const char* title) {
    if (!glfwInit()) {
        printf("[C-FATAL] Failed to initialize GLFW.\n");
        exit(EXIT_FAILURE);
    }

    // STEP 1: Tell GLFW not to create an OpenGL context
    glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
    glfwWindowHint(GLFW_RESIZABLE, GLFW_FALSE); // Keep it simple during refactor

    GLFWwindow* window = glfwCreateWindow(width, height, title, NULL, NULL);
    if (!window) {
        printf("[C-FATAL] Failed to create GLFW window.\n");
        glfwTerminate();
        exit(EXIT_FAILURE);
    }

    return window;
}

void init_vulkan_scaffolding(GLFWwindow* window) {
    // STEP 2: Vulkan Scaffolding Hook
    // This is where we will map the swapchain/framebuffers.
    // For now, we ensure GLFW can actually find Vulkan on the system.
    uint32_t extensionCount = 0;
    vkEnumerateInstanceExtensionProperties(NULL, &extensionCount, NULL);
    printf("[C-VULKAN] Supported Vulkan Extensions: %u\n", extensionCount);

    // Future integration:
    // 1. Create VkInstance
    // 2. glfwCreateWindowSurface(instance, window, NULL, &surface);
    // 3. Build Swapchain dependent on surface format & V-Sync (VK_PRESENT_MODE_FIFO_KHR)
}

// --- MAIN C-THREAD (Vulkan Renderer & OS Events) ---
int main(int argc, char** argv) {
    printf("[C-CORE] Booting Minified Concurrent Pipeline...\n");

    // 1. Setup OS Window & Vulkan Surface Ready-State
    GLFWwindow* window = init_glfw_window(1280, 720, "Lock-Free Swarm Engine");
    init_vulkan_scaffolding(window);

    // 2. Initialize Inter-Thread Communication
    vibe_init_mailbox();

    // 3. Launch the Lua VM in an isolated thread
    vmath_thread_t lua_thread = vmath_thread_start(lua_co_overlord_loop, NULL);

    int frame_count = 0;

    // Main Render Loop (Tied to Monitor Refresh via Vulkan Presentation)
    while (vibe_get_is_running()) {

        // Handle OS events (Window closing, input, etc.)
        glfwPollEvents();
        if (glfwWindowShouldClose(window)) {
            printf("[C-CORE] Window closed by user. Initiating graceful shutdown...\n");
            vibe_trigger_shutdown(); // Signals Lua to terminate
        }

        // Lock-Free read of the latest physics data computed by Lua
        vibe_acquire_newest_frame();

        // TODO: Map g_engine.render_index to the Vulkan Command Buffer
        // -> Bind SoA Buffers -> vkCmdDraw -> vkQueuePresentKHR (Handles V-Sync Blocking)

        if (frame_count % 30 == 0) {
            printf("[C-RENDER] Drawing from Buffer Index: %d\n", g_engine.render_index);
        }
        frame_count++;

        // Temporary CPU throttle until Vulkan vkQueuePresentKHR provides native V-Sync blocking
        SLEEP_MS(16);
    }

    printf("\n[C-CORE] Shutdown triggered. Waiting for Lua handshake...\n");

    // Deadlock-free teardown: Wait for Lua to acknowledge the shutdown signal
    while (atomic_load_explicit(&g_engine.mailbox.lua_finished, memory_order_acquire) == 0) {
        SLEEP_MS(1);
    }

    vmath_thread_join(lua_thread);

    // Clean up OS resources
    glfwDestroyWindow(window);
    glfwTerminate();

    printf("[C-CORE] Clean Exit.\n");
    return 0;
}

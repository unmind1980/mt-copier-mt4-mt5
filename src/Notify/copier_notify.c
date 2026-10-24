//+------------------------------------------------------------------+
//| copier_notify.c - Micro companion DLL for MT4/MT5 ultra-low       |
//|                   latency ZeroMQ socket event notification.     |
//|                                                                  |
//| Watches a ZeroMQ socket non-blockingly on a dedicated thread,    |
//| and immediately interrupts the MetaTrader chart message pump via |
//| PostMessageW(hwnd, WM_KEYDOWN, VK_F24, 0) upon inbound packets.  |
//| Bypasses the 10~20ms Windows GUI timer delay down to < 0.2ms.   |
//+------------------------------------------------------------------+

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>

#define ZMQ_POLLIN 1

#pragma pack(push, 8)
typedef struct {
    void     *socket;
    uintptr_t fd;
    short     events;
    short     revents;
#if defined(_WIN64) || defined(__x86_64__)
    int       __unused;
#endif
} zmq_pollitem_t;
#pragma pack(pop)

typedef int (__cdecl *fn_zmq_poll)(zmq_pollitem_t *items, int nitems, long timeout);

typedef struct {
    void           *socket;
    HWND            hwnd;
    int             key_code;
    HANDLE          thread;
    volatile LONG   running;
    volatile LONG   notified;
    fn_zmq_poll     pfn_poll;
} NotifierCtx;

static DWORD WINAPI WatcherThread(LPVOID lpParam)
{
    NotifierCtx *ctx = (NotifierCtx*)lpParam;
    if (!ctx || !ctx->socket || !ctx->pfn_poll || !ctx->hwnd)
        return 1;

    zmq_pollitem_t items[1];
    items[0].socket = ctx->socket;
    items[0].fd = 0;
    items[0].events = ZMQ_POLLIN;
    items[0].revents = 0;
#if defined(_WIN64) || defined(__x86_64__)
    items[0].__unused = 0;
#endif

    while (InterlockedCompareExchange(&ctx->running, 1, 1) == 1)
    {
        // Poll with 50ms timeout so thread termination responds promptly (<50ms)
        int rc = ctx->pfn_poll(items, 1, 50);
        if (rc > 0 && (items[0].revents & ZMQ_POLLIN))
        {
            // Edge-triggered notification: send message once until MQL acknowledges
            if (InterlockedCompareExchange(&ctx->notified, 1, 0) == 0)
            {
                PostMessageW(ctx->hwnd, WM_KEYDOWN, (WPARAM)ctx->key_code, 0);
            }
        }
    }

    return 0;
}

__declspec(dllexport) void* __stdcall CopierNotifyStart(void *socket, void *hwnd_chart, int key_code)
{
    if (!socket || !hwnd_chart)
        return NULL;

    HMODULE hZmq = GetModuleHandleA("libzmq.dll");
    if (!hZmq)
        hZmq = LoadLibraryA("libzmq.dll");
    if (!hZmq)
        return NULL;

    fn_zmq_poll pfn = (fn_zmq_poll)(void*)GetProcAddress(hZmq, "zmq_poll");
    if (!pfn)
        return NULL;

    NotifierCtx *ctx = (NotifierCtx*)HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(NotifierCtx));
    if (!ctx)
        return NULL;

    ctx->socket = socket;
    ctx->hwnd = (HWND)hwnd_chart;
    ctx->key_code = (key_code > 0) ? key_code : 0x87; // Default VK_F24 (0x87)
    ctx->running = 1;
    ctx->notified = 0;
    ctx->pfn_poll = pfn;

    ctx->thread = CreateThread(NULL, 0, WatcherThread, ctx, 0, NULL);
    if (!ctx->thread)
    {
        HeapFree(GetProcessHeap(), 0, ctx);
        return NULL;
    }

    return (void*)ctx;
}

__declspec(dllexport) void __stdcall CopierNotifyAck(void *handle)
{
    if (!handle)
        return;
    NotifierCtx *ctx = (NotifierCtx*)handle;
    InterlockedExchange(&ctx->notified, 0);
}

__declspec(dllexport) void __stdcall CopierNotifyStop(void *handle)
{
    if (!handle)
        return;
    NotifierCtx *ctx = (NotifierCtx*)handle;
    InterlockedExchange(&ctx->running, 0);

    if (ctx->thread)
    {
        WaitForSingleObject(ctx->thread, 200);
        CloseHandle(ctx->thread);
        ctx->thread = NULL;
    }

    HeapFree(GetProcessHeap(), 0, ctx);
}

BOOL WINAPI DllMain(HINSTANCE hinstDLL, DWORD fdwReason, LPVOID lpvReserved)
{
    (void)hinstDLL;
    (void)fdwReason;
    (void)lpvReserved;
    return TRUE;
}

/*
 * Proxy version.dll untuk meneruskan instruksi syscall Windows `int 0x2e` (cd 2e)
 * ke `__wine_syscall_dispatcher` milik Wine di `[0x7ffe1000]`.
 *
 * Game yang memakai VMProtect (misalnya UnityPlayer.dll pada Car Parking Multiplayer 2)
 * mengeksekusi `cd 2e` secara langsung. Di macOS/Rosetta, hal itu memicu
 * EXCEPTION_ACCESS_VIOLATION (ExceptionInformation = {0, ~0}) dan crash 0xc0000142.
 * VEH ini mengalihkan `int 0x2e` ke stub kecil yang memanggil dispatcher Wine lalu
 * melompat kembali ke `rip + 2`.
 */
#include <windows.h>

#define MAX_STUBS 2048
#define STUB_SIZE 32

static unsigned char *g_stub_page;
static ULONG64 g_stub_rips[MAX_STUBS];
static LONG g_stub_count;
static volatile LONG g_lock;

static void lock_acquire(void)
{
    while (_InterlockedCompareExchange(&g_lock, 1, 0) != 0)
        YieldProcessor();
}

static void lock_release(void)
{
    _InterlockedExchange(&g_lock, 0);
}

/*
 * Tata letak stub per-callsite (32 byte):
 * +0x00: eb 09                   jmp short +0x0b  (tujuan setelah dispatcher menyesuaikan rip)
 * +0x02: 90 90                   nop; nop
 * +0x04: ff 14 25 00 10 fe 7f    call qword ptr [0x7ffe1000]  <-- entry point dari VEH
 *                                Push (stub + 0x0b); __wine_syscall_dispatcher mengurangi rip
 *                                sebesar 0x0b sehingga kembali ke stub + 0x00 dengan rsp utuh.
 * +0x0b: ff 25 00 00 00 00       jmp qword ptr [rip + 0]      (lompat ke alamat 64-bit di +0x11)
 * +0x11: <uint64_t orig_rip + 2>
 */
static ULONG64 get_or_make_stub(ULONG64 orig_rip)
{
    LONG i, n;
    unsigned char *s;
    ULONG64 resume_rip = orig_rip + 2;

    lock_acquire();
    n = g_stub_count;
    for (i = 0; i < n; i++)
    {
        if (g_stub_rips[i] == orig_rip)
        {
            lock_release();
            return (ULONG64)(g_stub_page + (SIZE_T)i * STUB_SIZE + 0x04);
        }
    }
    if (n >= MAX_STUBS || !g_stub_page)
    {
        lock_release();
        return 0;
    }

    s = g_stub_page + (SIZE_T)n * STUB_SIZE;
    s[0x00] = 0xeb; s[0x01] = 0x09;
    s[0x02] = 0x90; s[0x03] = 0x90;
    s[0x04] = 0xff; s[0x05] = 0x14; s[0x06] = 0x25;
    s[0x07] = 0x00; s[0x08] = 0x10; s[0x09] = 0xfe; s[0x0a] = 0x7f;
    s[0x0b] = 0xff; s[0x0c] = 0x25;
    s[0x0d] = 0x00; s[0x0e] = 0x00; s[0x0f] = 0x00; s[0x10] = 0x00;
    *(ULONG64 *)(s + 0x11) = resume_rip;

    FlushInstructionCache(GetCurrentProcess(), s, STUB_SIZE);
    g_stub_rips[n] = orig_rip;
    _InterlockedIncrement(&g_stub_count);
    lock_release();
    return (ULONG64)(s + 0x04);
}

static LONG WINAPI veh_int2e(PEXCEPTION_POINTERS ep)
{
    const unsigned char *rip;
    ULONG64 entry;

    if (!ep || !ep->ExceptionRecord || !ep->ContextRecord)
        return EXCEPTION_CONTINUE_SEARCH;
    if (ep->ExceptionRecord->ExceptionCode != EXCEPTION_ACCESS_VIOLATION)
        return EXCEPTION_CONTINUE_SEARCH;
    if (ep->ExceptionRecord->NumberParameters < 2 ||
        ep->ExceptionRecord->ExceptionInformation[0] != 0 ||
        ep->ExceptionRecord->ExceptionInformation[1] != ~(ULONG_PTR)0)
        return EXCEPTION_CONTINUE_SEARCH;

    rip = (const unsigned char *)ep->ContextRecord->Rip;
    if (!rip || rip[0] != 0xcd || rip[1] != 0x2e)
        return EXCEPTION_CONTINUE_SEARCH;
    if (!*(void * const *)0x7ffe1000)
        return EXCEPTION_CONTINUE_SEARCH;

    entry = get_or_make_stub((ULONG64)rip);
    if (!entry)
        return EXCEPTION_CONTINUE_SEARCH;

    ep->ContextRecord->Rip = entry;
    return EXCEPTION_CONTINUE_EXECUTION;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved)
{
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH)
    {
        DisableThreadLibraryCalls(inst);
        g_stub_page = (unsigned char *)VirtualAlloc(
            NULL, MAX_STUBS * STUB_SIZE, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
        if (g_stub_page)
        {
            AddVectoredExceptionHandler(1, veh_int2e);
            /* Penanda "int2e-shim: " juga dipakai compat_run.sh untuk mengenali DLL ini. */
            OutputDebugStringA("int2e-shim: VEH int 0x2e -> __wine_syscall_dispatcher active\n");
        }
    }
    return TRUE;
}

DWORD WINAPI shim_VerFindFileA(DWORD f, LPCSTR a, LPCSTR b, LPCSTR c, LPSTR d, PUINT e, LPSTR g, PUINT h)
{
    (void)f; (void)a; (void)b; (void)c; (void)d; (void)e; (void)g; (void)h;
    return 0;
}

DWORD WINAPI shim_VerFindFileW(DWORD f, LPCWSTR a, LPCWSTR b, LPCWSTR c, LPWSTR d, PUINT e, LPWSTR g, PUINT h)
{
    (void)f; (void)a; (void)b; (void)c; (void)d; (void)e; (void)g; (void)h;
    return 0;
}

DWORD WINAPI shim_VerInstallFileA(DWORD f, LPCSTR a, LPCSTR b, LPCSTR c, LPCSTR d, LPCSTR e, LPSTR g, PUINT h)
{
    (void)f; (void)a; (void)b; (void)c; (void)d; (void)e; (void)g; (void)h;
    return VIF_CANNOTREADSRC;
}

DWORD WINAPI shim_VerInstallFileW(DWORD f, LPCWSTR a, LPCWSTR b, LPCWSTR c, LPCWSTR d, LPCWSTR e, LPWSTR g, PUINT h)
{
    (void)f; (void)a; (void)b; (void)c; (void)d; (void)e; (void)g; (void)h;
    return VIF_CANNOTREADSRC;
}

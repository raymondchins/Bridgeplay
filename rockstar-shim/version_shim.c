/*
 * version.dll for the Rockstar Games Launcher and GTA V Legacy (gamefix ROCKSTAR_SHIM=1).
 * The run script copies it next to SocialClubHelper.exe and next to the game's exe, and
 * sets version=n,b. Every export forwards to kernelbase/kernel32; DllMain does one job
 * per process and nothing in any other process:
 *
 * SocialClubHelper.exe (CEF): the launcher's sign-in and main windows are child windows
 *   that Chromium's GPU/viz process paints from another process. A winemac process cannot
 *   draw into another process's window, so they stay blank. The CEF browser process gets
 *   --in-process-gpu --disable-gpu --disable-gpu-compositing --disable-software-rasterizer,
 *   so it composites in software into its own window and starts no SwiftShader in process
 *   (which sometimes kept the window from being created). Wine's kernelbase caches the command line (GetCommandLineW reads
 *   command_lineW), so that copy is pointed at the new one too. The launcher also starts
 *   CEF with the game folder as working directory; SetDllDirectoryW(L"") keeps a d3d11 or
 *   dxgi there out of CEF's DLL search.
 *
 * GTA5.exe on DXVK: the game makes its own DXGI factory and passes its adapter to d3d11.
 *   On WineCX "dxgi.dll" is CrossOver's D3DMetal dxgi, whose CreateSwapChain fails for
 *   DXVK's device, and the game deadlocks in its exception handler. NOTPROTON_ROCKSTAR_DXGI
 *   names DXVK's dxgi under another file name (dxgx.dll, so the dxgi=b override does not
 *   apply to it). It is loaded and registered in the loader as dxgi.dll: BaseDllName is
 *   renamed and the entry moved to the hash bucket of its new name, so later
 *   LoadLibrary/GetModuleHandle("dxgi.dll") return it.
 *
 * Messages go to OutputDebugString (WINEDEBUG=+debugstr).
 */
#include <windows.h>
#include <winternl.h>

static void say(const char *msg)
{
    OutputDebugStringA(msg);
}

static void copy_bytes(void *d, const void *s, SIZE_T n)
{
    char *dd = d;
    const char *ss = s;
    while (n--) *dd++ = *ss++;
}

static int has_substr(const WCHAR *s, SIZE_T len, const WCHAR *pat)
{
    SIZE_T i, j;
    for (i = 0; i < len; i++)
    {
        for (j = 0; pat[j] && i + j < len && s[i + j] == pat[j]; j++) ;
        if (!pat[j]) return 1;
    }
    return 0;
}

static int exe_is(const WCHAR *name)
{
    WCHAR path[MAX_PATH];
    DWORD n = GetModuleFileNameW(NULL, path, MAX_PATH);
    if (!n || n >= MAX_PATH) return 0;
    while (n && path[n - 1] != '\\') n--;
    return !lstrcmpiW(path + n, name);
}

/* --- SocialClubHelper.exe --- */

static const WCHAR cef_switches[] = L" --in-process-gpu --disable-gpu --disable-gpu-compositing --disable-software-rasterizer";

/* Wine's GetCommandLineW is "mov rax, [rip+disp32]; ret". Anything else is left alone. */
static int point_kernelbase_cache(WCHAR *buf)
{
    HMODULE kb = GetModuleHandleW(L"kernelbase.dll");
    const unsigned char *fn;
    int disp;

    if (!kb) return 0;
    fn = (const unsigned char *)GetProcAddress(kb, "GetCommandLineW");
    if (!fn || fn[0] != 0x48 || fn[1] != 0x8b || fn[2] != 0x05 || fn[7] != 0xc3) return 0;
    copy_bytes(&disp, fn + 3, sizeof(disp));
    *(WCHAR **)(fn + 7 + disp) = buf;
    return 1;
}

static void cef_browser_switches(void)
{
    PEB *peb = (PEB *)__readgsqword(0x60);
    UNICODE_STRING *cl = &peb->ProcessParameters->CommandLine;
    USHORT extra = sizeof(cef_switches) - sizeof(WCHAR);
    WCHAR *buf;

    if (!cl->Buffer) return;
    /* Renderers, utilities and the GPU process carry --type=; only the browser is changed. */
    if (has_substr(cl->Buffer, cl->Length / sizeof(WCHAR), L"--type=")) return;
    if (has_substr(cl->Buffer, cl->Length / sizeof(WCHAR), L"--in-process-gpu")) return;
    if ((ULONG)cl->Length + extra + sizeof(WCHAR) > 0xfffe) return;
    buf = HeapAlloc(GetProcessHeap(), 0, cl->Length + extra + sizeof(WCHAR));
    if (!buf) return;
    copy_bytes(buf, cl->Buffer, cl->Length);
    copy_bytes((char *)buf + cl->Length, cef_switches, sizeof(cef_switches));
    cl->Buffer = buf;
    cl->Length += extra;
    cl->MaximumLength = cl->Length + sizeof(WCHAR);
    say(point_kernelbase_cache(buf) ? "rockstar-shim: CEF browser composites in process\n"
                                    : "rockstar-shim: GetCommandLineW not recognised, CEF switches only in the PEB\n");
}

/* --- GTA5.exe --- */

struct ldr_entry
{
    LIST_ENTRY InLoadOrderLinks;
    LIST_ENTRY InMemoryOrderLinks;
    LIST_ENTRY InInitializationOrderLinks;
    void *DllBase;
    void *EntryPoint;
    ULONG SizeOfImage;
    UNICODE_STRING FullDllName;
    UNICODE_STRING BaseDllName;
    ULONG Flags;
    SHORT LoadCount;
    SHORT TlsIndex;
    LIST_ENTRY HashLinks;
};

#define HASH_MAP_SIZE 32

static WCHAR up(WCHAR c) { return (c >= 'a' && c <= 'z') ? c - 32 : c; }

/* kind 0: Windows 8+ (and Wine), 1: Windows 7, 2: older, first letter. */
static ULONG name_hash(const UNICODE_STRING *n, int kind)
{
    ULONG h = 0, i, len = n->Length / sizeof(WCHAR);
    if (kind == 2) return len ? (ULONG)(up(n->Buffer[0]) - 'A') & (HASH_MAP_SIZE - 1) : 0;
    for (i = 0; i < len; i++) h = h * (kind == 0 ? 65599 : 0x1003f) + up(n->Buffer[i]);
    return h & (HASH_MAP_SIZE - 1);
}

static int is_module_hash_node(LIST_ENTRY *mods, LIST_ENTRY *node)
{
    LIST_ENTRY *e;
    for (e = mods->Flink; e != mods; e = e->Flink)
        if (&CONTAINING_RECORD(e, struct ldr_entry, InLoadOrderLinks)->HashLinks == node) return 1;
    return 0;
}

/* The bucket array is private to ntdll. Each module's HashLinks ring holds one node that is
 * not a module: its bucket head. The hash variant whose buckets line up for every module
 * gives the array; with none, nothing is changed. Runs under the loader lock (DllMain). */
static int rehash_entry(struct ldr_entry *target)
{
    PEB *peb = (PEB *)__readgsqword(0x60);
    LIST_ENTRY *mods = (LIST_ENTRY *)((char *)peb->Ldr + 0x10); /* InLoadOrderModuleList */
    LIST_ENTRY *e, *n, *table = NULL;
    int kind;

    for (kind = 0; kind < 3 && !table; kind++)
    {
        LIST_ENTRY *base = NULL;
        int ok = 1, seen = 0;
        for (e = mods->Flink; e != mods && ok; e = e->Flink)
        {
            struct ldr_entry *m = CONTAINING_RECORD(e, struct ldr_entry, InLoadOrderLinks);
            LIST_ENTRY *b;
            if (m == target || !m->BaseDllName.Buffer || !m->HashLinks.Flink) continue;
            for (n = m->HashLinks.Flink; n != &m->HashLinks && is_module_hash_node(mods, n); n = n->Flink) ;
            if (n == &m->HashLinks) { ok = 0; break; }
            b = n - name_hash(&m->BaseDllName, kind);
            if (!base) base = b;
            else if (b != base) ok = 0;
            seen++;
        }
        if (ok && seen > 3) table = base;
    }
    if (!table) return 0;
    kind--;
    target->HashLinks.Blink->Flink = target->HashLinks.Flink;
    target->HashLinks.Flink->Blink = target->HashLinks.Blink;
    n = table + name_hash(&target->BaseDllName, kind);
    target->HashLinks.Flink = n;
    target->HashLinks.Blink = n->Blink;
    n->Blink->Flink = &target->HashLinks;
    n->Blink = &target->HashLinks;
    return 1;
}

static WCHAR dxgi_name[] = L"dxgi.dll";

static void gta_dxvk_dxgi(void)
{
    WCHAR path[MAX_PATH];
    DWORD n = GetEnvironmentVariableW(L"NOTPROTON_ROCKSTAR_DXGI", path, MAX_PATH);
    PEB *peb = (PEB *)__readgsqword(0x60);
    LIST_ENTRY *mods = (LIST_ENTRY *)((char *)peb->Ldr + 0x10), *e;
    HMODULE h;

    if (!n || n >= MAX_PATH) return; /* not on DXVK */
    if (GetModuleHandleW(L"dxgi.dll")) { say("rockstar-shim: dxgi.dll already loaded\n"); return; }
    if (!(h = LoadLibraryW(path))) { say("rockstar-shim: DXVK dxgi did not load\n"); return; }
    for (e = mods->Flink; e != mods; e = e->Flink)
    {
        struct ldr_entry *m = CONTAINING_RECORD(e, struct ldr_entry, InLoadOrderLinks);
        if (m->DllBase != h) continue;
        m->BaseDllName.Buffer = dxgi_name;
        m->BaseDllName.Length = sizeof(dxgi_name) - sizeof(WCHAR);
        m->BaseDllName.MaximumLength = sizeof(dxgi_name);
        if (!rehash_entry(m)) say("rockstar-shim: loader hash table not found\n");
        say(GetModuleHandleW(L"dxgi.dll") == h ? "rockstar-shim: DXVK dxgi is dxgi.dll\n"
                                               : "rockstar-shim: dxgi.dll does not resolve to DXVK dxgi\n");
        return;
    }
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved)
{
    if (reason != DLL_PROCESS_ATTACH) return TRUE;
    DisableThreadLibraryCalls(inst);
    if (exe_is(L"SocialClubHelper.exe"))
    {
        SetDllDirectoryW(L"");
        cef_browser_switches();
    }
    else if (exe_is(L"GTA5.exe"))
        gta_dxvk_dxgi();
    return TRUE;
}

/* Not in kernelbase; nothing the shim sits next to imports them. */
DWORD WINAPI shim_VerFindFileA(DWORD f, LPCSTR a, LPCSTR b, LPCSTR c, LPSTR d, PUINT e, LPSTR g, PUINT h) { return 0; }
DWORD WINAPI shim_VerFindFileW(DWORD f, LPCWSTR a, LPCWSTR b, LPCWSTR c, LPWSTR d, PUINT e, LPWSTR g, PUINT h) { return 0; }
DWORD WINAPI shim_VerInstallFileA(DWORD f, LPCSTR a, LPCSTR b, LPCSTR c, LPCSTR d, LPCSTR e, LPSTR g, PUINT h) { return VIF_CANNOTREADSRC; }
DWORD WINAPI shim_VerInstallFileW(DWORD f, LPCWSTR a, LPCWSTR b, LPCWSTR c, LPCWSTR d, LPCWSTR e, LPWSTR g, PUINT h) { return VIF_CANNOTREADSRC; }

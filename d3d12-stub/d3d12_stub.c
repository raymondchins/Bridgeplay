/*
 * d3d12.dll for the dxmt backend on a WineCX engine with D3DMetal (#2513). DXMT has no
 * D3D12, and the engine's builtin d3d12 is Apple's, which reads a null pointer when a game
 * hands it DXMT's DXGI adapter, before the game can fall back to D3D11. This one answers
 * like Windows on a GPU without D3D12: no device, so the game takes its D3D11 path.
 * The ordinals are Windows' (Unity imports D3D12CreateDevice and D3D12GetDebugInterface
 * by ordinal).
 */
#include <windows.h>

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved)
{
    return TRUE;
}

HRESULT WINAPI D3D12CreateDevice(IUnknown *adapter, int feature_level, REFIID iid, void **device)
{
    if (device) *device = NULL;
    return DXGI_ERROR_UNSUPPORTED;
}

HRESULT WINAPI D3D12GetDebugInterface(REFIID iid, void **debug)
{
    if (debug) *debug = NULL;
    return E_NOINTERFACE;
}

HRESULT WINAPI D3D12GetInterface(REFCLSID clsid, REFIID iid, void **object)
{
    if (object) *object = NULL;
    return E_NOINTERFACE;
}

HRESULT WINAPI D3D12EnableExperimentalFeatures(UINT count, const IID *iids, void *configs, UINT *sizes)
{
    return E_NOINTERFACE;
}

HRESULT WINAPI D3D12SerializeRootSignature(const void *desc, int version, void **blob, void **error)
{
    if (blob) *blob = NULL;
    if (error) *error = NULL;
    return E_NOTIMPL;
}

HRESULT WINAPI D3D12SerializeVersionedRootSignature(const void *desc, void **blob, void **error)
{
    if (blob) *blob = NULL;
    if (error) *error = NULL;
    return E_NOTIMPL;
}

HRESULT WINAPI D3D12CreateRootSignatureDeserializer(const void *data, SIZE_T size, REFIID iid, void **out)
{
    if (out) *out = NULL;
    return E_NOTIMPL;
}

HRESULT WINAPI D3D12CreateVersionedRootSignatureDeserializer(const void *data, SIZE_T size, REFIID iid, void **out)
{
    if (out) *out = NULL;
    return E_NOTIMPL;
}

#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <mscoree.h>
#include <stdio.h>
#include <string.h>

typedef HRESULT (WINAPI *BindRuntime)(LPCWSTR, LPCWSTR, DWORD,
                                      REFCLSID, REFIID, void **);

/* Report each boundary while activating only the runtime, with no assembly. */
int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    puts("before_LoadLibrary_mscoree");
    HMODULE module = LoadLibraryW(L"mscoree.dll");
    if (!module) {
        printf("FAIL LoadLibrary error=%lu\n", GetLastError());
        return 1;
    }
    puts("after_LoadLibrary_mscoree");
    FARPROC address = GetProcAddress(module, "CorBindToRuntimeEx");
    if (!address) {
        printf("FAIL GetProcAddress error=%lu\n", GetLastError());
        FreeLibrary(module);
        return 1;
    }
    BindRuntime bind;
    /* Windows exports use same-sized function pointers on each target ABI. */
    _Static_assert(sizeof(bind) == sizeof(address), "function pointer size");
    memcpy(&bind, &address, sizeof(bind));
    ICorRuntimeHost *host = NULL;
    puts("before_CorBindToRuntimeEx_v4");
    HRESULT status = bind(L"v4.0.30319", NULL, 0, &CLSID_CorRuntimeHost,
                          &IID_ICorRuntimeHost, (void **)&host);
    printf("CorBindToRuntimeEx=0x%08lx\n", status);
    if (FAILED(status)) {
        FreeLibrary(module);
        return 1;
    }
    puts("before_ICorRuntimeHost_Start");
    status = ICorRuntimeHost_Start(host);
    printf("ICorRuntimeHost_Start=0x%08lx\n", status);
    ICorRuntimeHost_Release(host);
    FreeLibrary(module);
    return FAILED(status) ? 1 : 0;
}

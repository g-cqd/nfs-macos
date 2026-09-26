#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <d3d11.h>
#include <stdio.h>

/* Owned-code probe: require FL11_0, verify a rendered pixel, then present it. */
int main(void)
{
    HWND window = NULL;
    IDXGISwapChain *swapchain = NULL;
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    ID3D11Texture2D *backbuffer = NULL, *staging = NULL;
    ID3D11RenderTargetView *target = NULL;
    D3D_FEATURE_LEVEL obtained = 0;
    const D3D_FEATURE_LEVEL requested = D3D_FEATURE_LEVEL_11_0;
    const float color[4] = {0.25f, 0.5f, 0.75f, 1.0f};
    const unsigned char expected[4] = {64, 128, 191, 255};
    int result = 1;
    HRESULT status;
    setvbuf(stdout, NULL, _IONBF, 0);

    window = CreateWindowExW(0, L"STATIC", L"Wine 11.18 D3D11 smoke",
                            WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                            100, 100, 640, 480, NULL, NULL, NULL, NULL);
    if (!window) {
        printf("FAIL CreateWindow error=%lu\n", GetLastError());
        goto done;
    }
    DXGI_SWAP_CHAIN_DESC swap = {0};
    swap.BufferDesc.Width = 640;
    swap.BufferDesc.Height = 480;
    swap.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    swap.SampleDesc.Count = 1;
    swap.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    swap.BufferCount = 2;
    swap.OutputWindow = window;
    swap.Windowed = TRUE;
    swap.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
    status = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE,
        NULL, 0, &requested, 1, D3D11_SDK_VERSION, &swap, &swapchain,
        &device, &obtained, &context);
    printf("device_status=0x%08lx feature_level=0x%04x\n", status, obtained);
    if (FAILED(status) || obtained != requested) goto done;
    status = IDXGISwapChain_GetBuffer(swapchain, 0, &IID_ID3D11Texture2D,
                                     (void **)&backbuffer);
    if (FAILED(status)) { printf("FAIL GetBuffer=%08lx\n", status); goto done; }
    status = ID3D11Device_CreateRenderTargetView(device,
        (ID3D11Resource *)backbuffer, NULL, &target);
    if (FAILED(status)) { printf("FAIL CreateRTV=%08lx\n", status); goto done; }
    D3D11_TEXTURE2D_DESC desc;
    ID3D11Texture2D_GetDesc(backbuffer, &desc);
    desc.Usage = D3D11_USAGE_STAGING;
    desc.BindFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    desc.MiscFlags = 0;
    status = ID3D11Device_CreateTexture2D(device, &desc, NULL, &staging);
    if (FAILED(status)) { printf("FAIL CreateStaging=%08lx\n", status); goto done; }
    ID3D11DeviceContext_ClearRenderTargetView(context, target, color);
    ID3D11DeviceContext_CopyResource(context, (ID3D11Resource *)staging,
                                    (ID3D11Resource *)backbuffer);
    D3D11_MAPPED_SUBRESOURCE mapped = {0};
    status = ID3D11DeviceContext_Map(context, (ID3D11Resource *)staging,
                                    0, D3D11_MAP_READ, 0, &mapped);
    if (FAILED(status)) { printf("FAIL Map=%08lx\n", status); goto done; }
    int pixel_ok = mapped.pData != NULL && mapped.RowPitch >= 640 * 4;
    if (pixel_ok) {
        /* RowPitch and fixed coordinates bound every read to this texture. */
        const unsigned char *pixel = (const unsigned char *)mapped.pData +
                                     240 * mapped.RowPitch + 320 * 4;
        printf("pixel_rgba=%u,%u,%u,%u\n", pixel[0], pixel[1], pixel[2], pixel[3]);
        for (unsigned i = 0; i < 4; ++i) {
            int delta = (int)pixel[i] - expected[i];
            if (delta < -1 || delta > 1) pixel_ok = 0;
        }
    }
    ID3D11DeviceContext_Unmap(context, (ID3D11Resource *)staging, 0);
    if (!pixel_ok) { puts("FAIL rendered pixel"); goto done; }
    for (unsigned frame = 0; frame < 180; ++frame) {
        MSG message;
        while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE)) {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        if (!IsWindow(window)) { puts("FAIL window closed early"); goto done; }
        ID3D11DeviceContext_ClearRenderTargetView(context, target, color);
        status = IDXGISwapChain_Present(swapchain, 1, 0);
        if (FAILED(status)) { printf("FAIL Present=%08lx\n", status); goto done; }
        MsgWaitForMultipleObjects(0, NULL, FALSE, 16, QS_ALLINPUT);
    }
    puts("PASS D3D11 FL11_0 rendered pixel and 180 nonfailed Present calls");
    result = 0;
done:
    if (target) ID3D11RenderTargetView_Release(target);
    if (staging) ID3D11Texture2D_Release(staging);
    if (backbuffer) ID3D11Texture2D_Release(backbuffer);
    if (context) ID3D11DeviceContext_Release(context);
    if (device) ID3D11Device_Release(device);
    if (swapchain) IDXGISwapChain_Release(swapchain);
    if (window && IsWindow(window)) DestroyWindow(window);
    return result;
}

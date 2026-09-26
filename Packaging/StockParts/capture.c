#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "models.h"

static unsigned attempts;
static int initialized;

/* Diagnostic only: execute on the game's message thread after frontend loading.
   The pinned PC 1.3 initializer writes through offset 0x30c. A guarded local
   0x400-byte RideInfo owns its parts references; no career records are changed. */
static void CALLBACK capture(HWND window, UINT message, UINT_PTR timer, DWORD time) {
  (void)window; (void)message; (void)time;
  if (++attempts > 180) { KillTimer(NULL, timer); return; }
  if (*(volatile unsigned int *)0x925e90 != 3 || !*(void **)0x9b09d8) return;
  KillTimer(NULL, timer);
  FILE *out = fopen("stock-capture.csv", "wb");
  if (!out) { OutputDebugStringA("StockCapture: cannot open output"); return; }
  int (__attribute__((thiscall)) *get_type)(void *) = (void *)0x5816b0;
  void (__attribute__((thiscall)) *init)(void *, int, int, int, int) = (void *)0x739a70;
  void (__attribute__((thiscall)) *stock)(void *) = (void *)0x7594a0;
  void *(__attribute__((thiscall)) *part)(void *, int) = (void *)0x739c70;
  unsigned short (__attribute__((thiscall)) *index)(void *, void *) = (void *)0x747bb0;
  const char *(*type_name)(int) = (void *)0x668370;
  for (unsigned model = 0; model < sizeof(signatures)/sizeof(signatures[0]); ++model) {
    unsigned int record[5] = {81, signatures[model][0], signatures[model][1], 2, 0};
    int type = get_type(record);
    if (type < 0 || type >= 95) { fprintf(out, "ERROR,type,%u,%d\n", model, type); break; }
    struct { unsigned int before; unsigned char bytes[0x400]; unsigned int after; } ride;
    memset(&ride, 0, sizeof ride);
    ride.before = ride.after = 0x12abcd34;
    init(ride.bytes, type, 0, 0, 0);
    stock(ride.bytes);
    if (ride.before != 0x12abcd34 || ride.after != 0x12abcd34) {
      fprintf(out, "ERROR,canary,%u\n", model); break;
    }
    const unsigned char *signature = (const unsigned char *)signatures[model];
    for (int byte = 0; byte < 8; ++byte) fprintf(out, "%02x", signature[byte]);
    fprintf(out, ",%.16s", type_name(type));
    for (int slot = 0; slot < 139; ++slot) {
      void *value = part(ride.bytes, slot);
      fprintf(out, ",%u", value ? index((void *)0x9b26a8, value) : 65535);
    }
    fputc('\n', out);
    fflush(out);
  }
  if (fclose(out)) OutputDebugStringA("StockCapture: output close failed");
}

__declspec(dllexport) void InitializeASI(void) {
  if (initialized++) return;
  unsigned char *base = (unsigned char *)GetModuleHandleA(NULL);
  if (base != (unsigned char *)0x400000) return;
  IMAGE_DOS_HEADER *dos = (void *)base;
  IMAGE_NT_HEADERS *nt = (void *)(base + dos->e_lfanew);
  if (nt->OptionalHeader.AddressOfEntryPoint != 0x3c4040) return;
  if (memcmp((void *)0x739a70, "\x8b\x44\x24\x04\x8b\xd1", 6) ||
      memcmp((void *)0x7594a0, "\x83\xec\x10\x53\x55\x56\x57", 7)) return;
  if (!SetTimer(NULL, 0, 1000, capture)) OutputDebugStringA("StockCapture: timer failed");
}

BOOL WINAPI DllMain(HINSTANCE module, DWORD reason, LPVOID reserved) {
  (void)module; (void)reserved;
  if (reason == DLL_PROCESS_ATTACH) InitializeASI();
  return TRUE;
}

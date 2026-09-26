#define UNICODE
#define _UNICODE
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <errno.h>

static const uintptr_t image_base = UINT64_C(0x140000000);
struct code_range { uintptr_t address; SIZE_T size; const char *name; };
static const struct code_range ranges[] = {
    {UINT64_C(0x144bdf500), 256, "exit"},
    {UINT64_C(0x14547ddc0), 512, "breakpoint"},
    {UINT64_C(0x1455d8600), 512, "context"}
};

/* A read stays inside one committed executable region of the known image. */
static BOOL valid_region(const MEMORY_BASIC_INFORMATION *region, uintptr_t address, SIZE_T size)
{
    const uintptr_t base = (uintptr_t)region->BaseAddress;
    const DWORD protect = region->Protect & 0xff;
    if (size == 0 || size > 512 || address < base || size > UINTPTR_MAX - address)
        return FALSE;
    if (region->RegionSize > UINTPTR_MAX - base || address + size > base + region->RegionSize)
        return FALSE;
    return region->State == MEM_COMMIT && region->Type == MEM_IMAGE &&
        (uintptr_t)region->AllocationBase == image_base &&
        !(region->Protect & (PAGE_GUARD | PAGE_NOACCESS)) &&
        (protect == PAGE_EXECUTE_READ || protect == PAGE_EXECUTE_READWRITE ||
         protect == PAGE_EXECUTE_WRITECOPY);
}

static int check_regions(void)
{
    MEMORY_BASIC_INFORMATION region = {0};
    region.BaseAddress = (void *)UINT64_C(0x144bdf000);
    region.AllocationBase = (void *)image_base;
    region.RegionSize = 4096;
    region.State = MEM_COMMIT;
    region.Type = MEM_IMAGE;
    region.Protect = PAGE_EXECUTE_READ;
    unsigned failures = 0;
    failures += !valid_region(&region, UINT64_C(0x144bdf500), 256);
    failures += valid_region(&region, UINT64_C(0x144bdfff0), 32);
    failures += valid_region(&region, UINT64_C(0x144bdf500), 513);
    failures += valid_region(&region, UINTPTR_MAX - 4, 16);
    region.Protect |= PAGE_GUARD;
    failures += valid_region(&region, UINT64_C(0x144bdf500), 256);
    region.Protect = PAGE_READONLY;
    failures += valid_region(&region, UINT64_C(0x144bdf500), 256);
    region.Protect = PAGE_EXECUTE_READ;
    region.Type = MEM_PRIVATE;
    failures += valid_region(&region, UINT64_C(0x144bdf500), 256);
    region.Type = MEM_IMAGE;
    region.AllocationBase = (void *)UINT64_C(0x180000000);
    failures += valid_region(&region, UINT64_C(0x144bdf500), 256);
    printf("region_checks=8 failures=%u\n", failures);
    return failures ? 1 : 0;
}

static BOOL capture(HANDLE process, DWORD pid, ULONGLONG run_id, unsigned phase)
{
    BYTE bytes[512];
    for (unsigned i = 0; i < sizeof(ranges) / sizeof(ranges[0]); ++i) {
        const struct code_range *range = &ranges[i];
        MEMORY_BASIC_INFORMATION region = {0};
        if (VirtualQueryEx(process, (void *)range->address, &region, sizeof(region)) != sizeof(region) ||
            !valid_region(&region, range->address, range->size)) {
            printf("range=%s rejected_region error=%lu\n", range->name, GetLastError());
            return FALSE;
        }
        SIZE_T read = 0;
        /* bytes owns 512 bytes; range size is bounded above before this read. */
        if (!ReadProcessMemory(process, (void *)range->address, bytes, range->size, &read) || read != range->size) {
            printf("range=%s read_error=%lu read_size=%llu\n", range->name, GetLastError(), (unsigned long long)read);
            return FALSE;
        }
        char path[256];
        const int length = snprintf(path, sizeof(path),
            "Logs\\code-capture-private\\pid%lu-t%llu-phase%u-%s.bin", pid, run_id, phase, range->name);
        if (length < 0 || (SIZE_T)length >= sizeof(path)) {
            puts("output_path_too_long");
            return FALSE;
        }
        HANDLE output = CreateFileA(path, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
        if (output == INVALID_HANDLE_VALUE) {
            printf("output_create_error=%lu\n", GetLastError());
            return FALSE;
        }
        DWORD written = 0;
        const BOOL ok = WriteFile(output, bytes, (DWORD)range->size, &written, NULL);
        const DWORD error = ok ? ERROR_SUCCESS : GetLastError();
        const BOOL closed = CloseHandle(output);
        if (!ok || written != range->size || !closed) {
            printf("output_write_error=%lu written=%lu close_ok=%d\n", error, written, closed);
            if (!DeleteFileA(path)) printf("partial_output_delete_error=%lu\n", GetLastError());
            return FALSE;
        }
        printf("phase=%u range=%s address=0x%llx bytes=%llu file=%s\n", phase, range->name,
            (unsigned long long)range->address, (unsigned long long)read, path);
    }
    return TRUE;
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc == 2 && strcmp(argv[1], "--check") == 0) return check_regions();
    if (argc != 2) { fputs("Usage: capture-nfs-code.exe <Windows PID>\n", stderr); return 2; }
    char *end = NULL;
    errno = 0;
    const unsigned long parsed = strtoul(argv[1], &end, 10);
    if (errno || end == argv[1] || *end || !parsed || parsed > UINT32_MAX) {
        fputs("Invalid PID\n", stderr); return 2;
    }
    const DWORD pid = (DWORD)parsed;
    HANDLE process = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ | SYNCHRONIZE, FALSE, pid);
    if (!process) { printf("open_error=%lu\n", GetLastError()); return 1; }
    WCHAR path[512];
    DWORD length = sizeof(path) / sizeof(path[0]);
    if (!QueryFullProcessImageNameW(process, 0, path, &length) ||
        _wcsicmp(path, L"C:\\Program Files\\EA Games\\Need for Speed\\NFS16.exe") != 0) {
        puts("Rejected process image"); CloseHandle(process); return 1;
    }
    const ULONGLONG run_id = GetTickCount64();
    int result = 0;
    for (unsigned phase = 0; phase < 3; ++phase) {
        if (phase) {
            const DWORD wait = WaitForSingleObject(process, 5000);
            if (wait != WAIT_TIMEOUT) {
                printf("process_finished_or_wait_failed result=%lu\n", wait); result = 1; break;
            }
        }
        if (!capture(process, pid, run_id, phase)) { result = 1; break; }
    }
    if (!CloseHandle(process)) { printf("process_close_error=%lu\n", GetLastError()); return 1; }
    return result;
}

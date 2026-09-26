#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0a00
#include <windows.h>
#include <winternl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#if !defined(__x86_64__)
#error This probe requires an x86-64 Windows target.
#endif

typedef NTSTATUS (WINAPI *allocate_fn)(HANDLE, PVOID *, SIZE_T *, ULONG, ULONG,
                                      MEM_EXTENDED_PARAMETER *, ULONG);
typedef NTSTATUS (WINAPI *release_fn)(HANDLE, PVOID *, SIZE_T *, ULONG);

_Static_assert(sizeof(allocate_fn) == sizeof(FARPROC), "Windows function pointer size");
_Static_assert(sizeof(release_fn) == sizeof(FARPROC), "Windows function pointer size");

static const uintptr_t range_low = UINT64_C(0x700000000000);
static const uintptr_t narrow_high = UINT64_C(0x7000001fffff);
static const uintptr_t wide_high = UINT64_C(0x7ffffffeffff);
static const SIZE_T reservation_size = 0x10000;
static unsigned failures;
static unsigned errors;

struct result {
    NTSTATUS status;
    BOOL valid;
};

static struct result reserve_range(const char *name, uintptr_t high,
                                   allocate_fn allocate, release_fn release)
{
    MEM_ADDRESS_REQUIREMENTS requirements = {0};
    MEM_EXTENDED_PARAMETER parameter = {0};
    struct result result = {0};
    PVOID base = NULL;
    SIZE_T size = reservation_size;
    uintptr_t address;

    requirements.LowestStartingAddress = (PVOID)range_low;
    requirements.HighestEndingAddress = (PVOID)high;
    requirements.Alignment = reservation_size;
    parameter.Type = MemExtendedParameterAddressRequirements;
    parameter.Pointer = &requirements;

    result.status = allocate(GetCurrentProcess(), &base, &size,
                             MEM_RESERVE | MEM_TOP_DOWN, PAGE_NOACCESS,
                             &parameter, 1);
    address = (uintptr_t)base;
    printf("%s allocate_status=%08" PRIx32 " address=%016" PRIx64
           " size=%" PRIu64 "\n", name, (uint32_t)result.status,
           (uint64_t)address, (uint64_t)size);
    if (result.status != 0) {
        ++failures;
        return result;
    }

    result.valid = base && size == reservation_size && address >= range_low &&
                   address <= high && size - 1 <= high - address &&
                   !(address & (reservation_size - 1));
    if (!result.valid) {
        ++failures;
        printf("FAIL %s returned reservation outside requested bounds\n", name);
    }

    /* Only a successful reservation is owned; release it without accessing it. */
    if (base) {
        NTSTATUS status;
        size = 0;
        status = release(GetCurrentProcess(), &base, &size, MEM_RELEASE);
        printf("%s release_status=%08" PRIx32 "\n", name, (uint32_t)status);
        if (status != 0) ++errors;
    } else {
        ++errors;
    }
    return result;
}

int main(void)
{
    HMODULE module = GetModuleHandleW(L"ntdll.dll");
    FARPROC allocate_address;
    FARPROC release_address;
    allocate_fn allocate;
    release_fn release;
    SYSTEM_INFO info;
    struct result before, wide, after;
    BOOL controls_valid;
    BOOL reproduced;

    setvbuf(stdout, NULL, _IONBF, 0);
    puts("address-ceiling-probe x64: three 64KiB reservations, no commit or access");
    printf("range_low=%016" PRIx64 " narrow_high=%016" PRIx64 " wide_high=%016" PRIx64 "\n",
           (uint64_t)range_low, (uint64_t)narrow_high, (uint64_t)wide_high);
    if (!module) {
        printf("ERROR ntdll module winerror=%lu\n", (unsigned long)GetLastError());
        return 2;
    }
    allocate_address = GetProcAddress(module, "NtAllocateVirtualMemoryEx");
    release_address = GetProcAddress(module, "NtFreeVirtualMemory");
    if (!allocate_address || !release_address) {
        puts("ERROR required native allocation exports unavailable");
        return 2;
    }
    /* GetProcAddress returns Windows function pointers with this representation. */
    memcpy(&allocate, &allocate_address, sizeof(allocate));
    memcpy(&release, &release_address, sizeof(release));

    GetSystemInfo(&info);
    printf("reported_maximum=%016" PRIx64 " allocation_granularity=%lu page_size=%lu\n",
           (uint64_t)(uintptr_t)info.lpMaximumApplicationAddress,
           (unsigned long)info.dwAllocationGranularity, (unsigned long)info.dwPageSize);
    if ((uintptr_t)info.lpMaximumApplicationAddress < wide_high ||
        info.dwAllocationGranularity != reservation_size ||
        !info.dwPageSize || reservation_size % info.dwPageSize) {
        puts("ERROR reported address range or allocation units cannot support probe");
        return 2;
    }

    before = reserve_range("narrow-before", narrow_high, allocate, release);
    if (errors) goto incomplete;
    wide = reserve_range("wide", wide_high, allocate, release);
    if (errors) goto incomplete;
    after = reserve_range("narrow-after", narrow_high, allocate, release);
    controls_valid = before.valid && after.valid;
    reproduced = controls_valid && !errors && (uint32_t)wide.status == UINT32_C(0xc0000017);
    printf("SUMMARY cases=3 failures=%u infrastructure_errors=%u controls_valid=%u"
           " wide_no_memory_reproduced=%u\n", failures, errors,
           (unsigned)controls_valid, (unsigned)reproduced);
    if (errors || !controls_valid) return 2;
    return failures ? 1 : 0;

incomplete:
    printf("SUMMARY incomplete=1 failures=%u infrastructure_errors=%u\n", failures, errors);
    return 2;
}

/* Tests the production helper and NtWriteVirtualMemory with controlled OS results. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

typedef void *HANDLE;
typedef uintptr_t ULONG_PTR;
typedef size_t SIZE_T;
typedef uint32_t DWORD;
typedef uint32_t NTSTATUS;
#define WINAPI
#define STATUS_SUCCESS 0
#define STATUS_ACCESS_DENIED 0xc0000022u
#define STATUS_PARTIAL_COPY 0x8000000du
#define STATUS_INVALID_PARAMETER 0xc000000du
#define STATUS_INVALID_ADDRESS 0xc0000141u
#define PAGE_NOACCESS 1u
#define PAGE_READONLY 2u
#define PAGE_READWRITE 4u
#define PAGE_WRITECOPY 8u
#define PAGE_EXECUTE 0x10u
#define PAGE_EXECUTE_READ 0x20u
#define PAGE_EXECUTE_READWRITE 0x40u
#define PAGE_EXECUTE_WRITECOPY 0x80u
#define PAGE_GUARD 0x100u
#define PAGE_NOCACHE 0x200u
#define PAGE_WRITECOMBINE 0x400u
#define MEM_COMMIT 0x1000u
#define MemoryBasicInformation 0
#define min(a, b) ((a) < (b) ? (a) : (b))
typedef struct {
    void *BaseAddress;
    void *AllocationBase;
    DWORD AllocationProtect;
    SIZE_T RegionSize;
    DWORD State, Protect, Type;
} MEMORY_BASIC_INFORMATION;
struct request { uintptr_t handle, addr; } request_data;
struct reply { SIZE_T written; } reply_data;
struct change { uintptr_t base; size_t size; DWORD protect; } changes[16];
static MEMORY_BASIC_INFORMATION regions[3];
static unsigned queries, protects, query_failure, protect_failure;
static unsigned failures, checks;
static int translated = 1, malformed;
static NTSTATUS write_status;
static SIZE_T write_count;

static int is_apple_silicon(void) { return translated; }
static int virtual_check_buffer_for_read(const void *p, SIZE_T s)
{ (void)p; (void)s; return 1; }
static uintptr_t wine_server_obj_handle(HANDLE p) { return (uintptr_t)p; }
static uintptr_t wine_server_client_ptr(void *p) { return (uintptr_t)p; }
static void wine_server_add_data(struct request *r, const void *p, SIZE_T s)
{ (void)r; (void)p; (void)s; }
static NTSTATUS wine_server_call(struct request *r)
{ (void)r; reply_data.written = write_count; return write_status; }
#define SERVER_START_REQ(x) do { struct request *req = &request_data; struct reply *reply = &reply_data;
#define SERVER_END_REQ } while (0)

static NTSTATUS NtQueryVirtualMemory(HANDLE process, void *address, int type,
    MEMORY_BASIC_INFORMATION *info, SIZE_T length, SIZE_T *returned)
{
    uintptr_t a = (uintptr_t)address;
    (void)process; (void)type; (void)length;
    ++queries;
    if (queries == query_failure) return STATUS_ACCESS_DENIED;
    for (unsigned i = 0; i < 3; ++i)
    {
        uintptr_t b = (uintptr_t)regions[i].BaseAddress;
        if (a >= b && a - b < regions[i].RegionSize)
        {
            *info = regions[i];
            if (malformed == 1) info->RegionSize = 0;
            if (malformed == 2) info->BaseAddress = (void *)(a + 1);
            *returned = sizeof(*info);
            return STATUS_SUCCESS;
        }
    }
    return STATUS_INVALID_ADDRESS;
}

static NTSTATUS NtProtectVirtualMemory(HANDLE process, void **address, SIZE_T *length,
                                       DWORD protection, DWORD *old)
{
    uintptr_t first = (uintptr_t)*address & ~(uintptr_t)0xfff;
    uintptr_t end = ((uintptr_t)*address + *length + 0xfff) & ~(uintptr_t)0xfff;
    (void)process;
    if (protects == 16) abort();
    changes[protects++] = (struct change){ first, end - first, protection };
    if (protects == protect_failure) { *old = PAGE_NOACCESS; return STATUS_ACCESS_DENIED; }
    for (unsigned i = 0; i < 3; ++i)
    {
        uintptr_t b = (uintptr_t)regions[i].BaseAddress;
        if (first >= b && first - b < regions[i].RegionSize) *old = regions[i].Protect;
        if (b < end && b + regions[i].RegionSize > first) regions[i].Protect = protection;
    }
    *address = (void *)first;
    *length = end - first;
    return STATUS_SUCCESS;
}

#include "production-under-test.inc"

static void reset(DWORD allocation, DWORD current)
{
    memset(regions, 0, sizeof(regions));
    memset(changes, 0, sizeof(changes));
    regions[0] = (MEMORY_BASIC_INFORMATION){ (void *)0x10000, (void *)0x10000,
        allocation, 0x1000, MEM_COMMIT, current, 0 };
    queries = protects = query_failure = protect_failure = 0;
    write_status = STATUS_SUCCESS;
    write_count = 1;
    translated = 1;
    malformed = 0;
}

static NTSTATUS write_at(uintptr_t address, SIZE_T count, SIZE_T *written)
{
    unsigned char buffer = 2;
    return NtWriteVirtualMemory((HANDLE)1, (void *)address, &buffer, count, written);
}

static void check(const char *name, int passed)
{
    ++checks;
    failures += !passed;
    printf("%s %s\n", passed ? "PASS" : "FAIL", name);
}

int main(void)
{
    SIZE_T written;
    NTSTATUS status;
    reset(PAGE_READWRITE, PAGE_EXECUTE_READWRITE);
    status = write_at(0x10001, 1, &written);
    check("current executable protection governs invalidation", !status && written == 1 &&
          protects == 2 && changes[0].protect == PAGE_READWRITE &&
          regions[0].Protect == PAGE_EXECUTE_READWRITE);

    reset(PAGE_EXECUTE_READWRITE, PAGE_READWRITE);
    status = write_at(0x10001, 1, &written);
    check("formerly executable current RW is untouched", !status && protects == 0);

    reset(PAGE_EXECUTE_READWRITE, PAGE_EXECUTE_READWRITE);
    regions[1] = regions[0]; regions[1].BaseAddress = (void *)0x11000;
    regions[1].Protect = PAGE_READWRITE;
    write_count = 2;
    status = write_at(0x10fff, 2, &written);
    check("mixed executable and RW permissions preserved", !status && protects == 2 &&
          changes[0].size == 0x1000 && regions[0].Protect == PAGE_EXECUTE_READWRITE &&
          regions[1].Protect == PAGE_READWRITE);

    reset(PAGE_READWRITE, PAGE_EXECUTE_READWRITE);
    regions[1] = regions[0]; regions[1].BaseAddress = (void *)0x11000;
    regions[1].Protect = PAGE_EXECUTE_READ;
    write_count = 2;
    status = write_at(0x10fff, 2, &written);
    check("distinct executable regions restored separately", !status && protects == 4 &&
          regions[0].Protect == PAGE_EXECUTE_READWRITE && regions[1].Protect == PAGE_EXECUTE_READ);

    for (unsigned execute = PAGE_EXECUTE; execute <= PAGE_EXECUTE_WRITECOPY; execute <<= 1)
        for (unsigned modifier = 0; modifier <= PAGE_WRITECOMBINE;
             modifier = modifier ? modifier << 1 : PAGE_GUARD)
        {
            char name[80];
            reset(execute | modifier, execute | modifier);
            status = write_at(0x10001, 1, &written);
            snprintf(name, sizeof(name), "permission and modifier preserved exec=%x modifier=%x", execute, modifier);
            check(name, !status && protects == 2 && changes[0].protect == ((execute >> 4) | modifier) &&
                  regions[0].Protect == (execute | modifier));
        }

    reset(PAGE_EXECUTE_READWRITE, PAGE_EXECUTE_READWRITE);
    write_count = 0;
    status = write_at(0x10001, 0, &written);
    check("zero write performs no query or protection change", !status && !written && !queries && !protects);

    reset(PAGE_READWRITE, PAGE_EXECUTE_READWRITE);
    write_count = 16;
    status = write_at(UINTPTR_MAX - 7, 16, &written);
    check("overflow rejected before query", status == STATUS_INVALID_PARAMETER && written == 16 && !queries && !protects);

    reset(PAGE_READWRITE, PAGE_EXECUTE_READWRITE);
    status = write_at(0x10fff, 1, &written);
    check("exclusive range end does not query following region", !status && queries == 1 && protects == 2);

    reset(PAGE_EXECUTE_READWRITE, PAGE_EXECUTE_READWRITE);
    query_failure = 1;
    status = write_at(0x10001, 1, &written);
    check("query failure propagated with written count", status == STATUS_ACCESS_DENIED && written == 1 && !protects);

    reset(PAGE_EXECUTE_READWRITE, PAGE_EXECUTE_READWRITE);
    protect_failure = 1;
    status = write_at(0x10001, 1, &written);
    check("removal failure does not restore uninitialized protection", status == STATUS_ACCESS_DENIED &&
          written == 1 && protects == 1 && regions[0].Protect == PAGE_EXECUTE_READWRITE);

    reset(PAGE_EXECUTE_READWRITE, PAGE_EXECUTE_READWRITE);
    protect_failure = 2;
    status = write_at(0x10001, 1, &written);
    check("restore failure reported without pretending rollback", status == STATUS_ACCESS_DENIED &&
          written == 1 && protects == 2 && regions[0].Protect == PAGE_READWRITE);

    reset(PAGE_READWRITE, PAGE_EXECUTE_READWRITE);
    write_status = STATUS_PARTIAL_COPY;
    status = write_at(0x10001, 2, &written);
    check("partial write invalidates only confirmed bytes and preserves status", status == STATUS_PARTIAL_COPY &&
          written == 1 && protects == 2 && changes[0].size == 0x1000);

    reset(PAGE_EXECUTE_READWRITE, PAGE_EXECUTE_READWRITE);
    write_status = STATUS_PARTIAL_COPY; query_failure = 1;
    status = write_at(0x10001, 2, &written);
    check("original write failure remains primary", status == STATUS_PARTIAL_COPY && written == 1);

    reset(PAGE_EXECUTE_READWRITE, PAGE_EXECUTE_READWRITE);
    write_status = STATUS_ACCESS_DENIED; write_count = 0;
    status = write_at(0x10001, 1, &written);
    check("failed zero-byte write performs no invalidation", status == STATUS_ACCESS_DENIED && !written && !queries);

    for (int mode = 1; mode <= 2; ++mode)
    {
        reset(PAGE_READWRITE, PAGE_EXECUTE_READWRITE); malformed = mode;
        status = write_at(0x10001, 1, &written);
        check(mode == 1 ? "empty query region rejected" : "query region beyond cursor rejected",
              status == STATUS_INVALID_ADDRESS && written == 1 && !protects);
    }

    reset(PAGE_EXECUTE_READWRITE, PAGE_EXECUTE_READWRITE); translated = 0;
    status = write_at(0x10001, 1, &written);
    check("nontranslated host bypasses workaround", !status && written == 1 && !queries && !protects);
    printf("SUMMARY checks=%u failures=%u\n", checks, failures);
    return failures ? 1 : 0;
}

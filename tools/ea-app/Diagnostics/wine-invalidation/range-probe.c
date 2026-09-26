#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef LONG NTSTATUS;
extern NTSTATUS NTAPI NtWriteVirtualMemory(HANDLE, void *, const void *, SIZE_T, SIZE_T *);
typedef int (*entry_fn)(void);
struct work { entry_fn entries[2]; HANDLE ready, proceed; unsigned mask; };
static unsigned checks, failures;

static void require(BOOL passed, const char *name)
{
    if (!passed) { printf("INFRA %s error=%lu\n", name, (unsigned long)GetLastError()); ExitProcess(2); }
}

static void check(BOOL passed, const char *name)
{
    ++checks;
    failures += !passed;
    printf("%s %s\n", passed ? "PASS" : "FAIL", name);
}

static int call_entries(const struct work *work, int expected, unsigned repetitions)
{
    int passed = 1;
    for (unsigned i = 0; i < repetitions; ++i)
        for (unsigned j = 0; j < 2; ++j)
            if ((work->mask & (1u << j)) && work->entries[j]() != expected) passed = 0;
    return passed;
}

static DWORD WINAPI worker(void *arg)
{
    struct work *work = arg;
    int before = call_entries(work, 1, 1000);
    if (!SetEvent(work->ready) || WaitForSingleObject(work->proceed, 10000) != WAIT_OBJECT_0) return 2;
    return before && call_entries(work, 2, 1) ? 0 : 1;
}

static void mixed_case(DWORD initial, DWORD first, DWORD second, const char *name)
{
    /* The controller owns both pages; the worker parks before any write/protection change. */
    unsigned char buffer[8192];
    const unsigned char code[] = {0xb8, 1, 0, 0, 0, 0xc3};
    DWORD protections[2] = {first, second}, old, worker_result;
    struct work work = {{NULL, NULL}, NULL, NULL, 0};
    unsigned char *pages = VirtualAlloc(NULL, sizeof(buffer), MEM_COMMIT | MEM_RESERVE, initial);
    SIZE_T written = ~(SIZE_T)0;
    MEMORY_BASIC_INFORMATION info;
    HANDLE thread;
    NTSTATUS status;
    int before, after;
    require(pages != NULL, "allocate two pages");
    memset(buffer, 0x90, sizeof(buffer));
    for (unsigned i = 0; i < 2; ++i)
    {
        void *address = pages + i * 4096 + 16;
        memcpy(buffer + i * 4096 + 16, code, sizeof(code));
        _Static_assert(sizeof(entry_fn) == sizeof(address), "x64 function pointer size");
        memcpy(&work.entries[i], &address, sizeof(address));
        if (protections[i] & 0xf0) work.mask |= 1u << i;
    }
    memcpy(pages, buffer, sizeof(buffer));
    for (unsigned i = 0; i < 2; ++i)
        require(VirtualProtect(pages + i * 4096, 4096, protections[i], &old), "set mixed protections");
    require(FlushInstructionCache(GetCurrentProcess(), pages, sizeof(buffer)), "initial flush");
    work.ready = CreateEventW(NULL, TRUE, FALSE, NULL);
    work.proceed = CreateEventW(NULL, TRUE, FALSE, NULL);
    require(work.ready != NULL && work.proceed != NULL, "create handshakes");
    before = call_entries(&work, 1, 1000);
    thread = CreateThread(NULL, 0, worker, &work, 0, NULL);
    require(thread != NULL, "create worker");
    require(WaitForSingleObject(work.ready, 10000) == WAIT_OBJECT_0, "worker parked");
    buffer[17] = buffer[4096 + 17] = 2;
    status = NtWriteVirtualMemory(GetCurrentProcess(), pages, buffer, sizeof(buffer), &written);
    require(FlushInstructionCache(GetCurrentProcess(), pages, sizeof(buffer)), "flush written pages");
    printf("CASE %s status=%08lx written=%llu\n", name, (unsigned long)(uint32_t)status,
           (unsigned long long)written);
    check(status == 0 && written == sizeof(buffer), "mixed write completed");
    for (unsigned i = 0; i < 2; ++i)
    {
        require(VirtualQuery(pages + i * 4096, &info, sizeof(info)) == sizeof(info), "query after write");
        printf("page=%u protect=%lx expected=%lx\n", i, (unsigned long)info.Protect,
               (unsigned long)protections[i]);
        check(info.Protect == protections[i], "region current protection preserved");
    }
    after = call_entries(&work, 2, 1);
    require(SetEvent(work.proceed), "release worker");
    require(WaitForSingleObject(thread, 10000) == WAIT_OBJECT_0, "join worker");
    require(GetExitCodeThread(thread, &worker_result), "worker exit code");
    check(before && after && worker_result == 0, "both warmed threads execute changed code");
    require(CloseHandle(thread) && CloseHandle(work.ready) && CloseHandle(work.proceed), "close handles");
    require(VirtualFree(pages, 0, MEM_RELEASE), "release pages");
}

int main(void)
{
    unsigned char value = 2;
    SIZE_T written;
    NTSTATUS status;
    void *page;
    mixed_case(PAGE_EXECUTE_READWRITE, PAGE_EXECUTE_READWRITE, PAGE_READWRITE, "RWX allocation mixed RWX/RW");
    mixed_case(PAGE_READWRITE, PAGE_READWRITE, PAGE_EXECUTE_READWRITE, "RW allocation mixed RW/RWX");
    mixed_case(PAGE_READWRITE, PAGE_EXECUTE_READWRITE, PAGE_EXECUTE_READ, "RW allocation mixed RWX/RX");
    page = VirtualAlloc(NULL, 4096, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    require(page != NULL, "allocate edge-case page");
    written = ~(SIZE_T)0;
    status = NtWriteVirtualMemory(GetCurrentProcess(), page, &value, 0, &written);
    check(status == 0 && written == 0, "zero native write succeeds with zero count");
    written = ~(SIZE_T)0;
    status = NtWriteVirtualMemory(NULL, page, &value, 1, &written);
    check(status != 0 && written == 0, "invalid process handle reports no write");
    require(VirtualFree(page, 0, MEM_RELEASE), "release edge-case page");
    printf("SUMMARY checks=%u failures=%u\n", checks, failures);
    return failures ? 1 : 0;
}

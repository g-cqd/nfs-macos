#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#if !defined(__x86_64__)
#error This probe requires an x86-64 Windows target.
#endif

typedef int (*entry_fn)(void);
static entry_fn entry;
static HANDLE ready, proceed;

static DWORD WINAPI worker(void *unused)
{
    int before = 0, after;
    (void)unused;
    for (unsigned i = 0; i < 1000; ++i) before = entry();
    if (!SetEvent(ready)) return 2;
    if (WaitForSingleObject(proceed, 5000) != WAIT_OBJECT_0) return 2;
    after = entry();
    printf("worker warm=%d after_write=%d\n", before, after);
    return before == 1 && after == 2 ? 0 : 1;
}

static int run_case(DWORD initial_protection, DWORD execution_protection, BOOL explicit_transition)
{
    /* Both threads stop calling this owned page before the controller writes it. */
    const unsigned char code[] = {0xb8, 1, 0, 0, 0, 0xc3};
    unsigned char replacement = 2;
    void *page = VirtualAlloc(NULL, 4096, MEM_COMMIT | MEM_RESERVE, initial_protection);
    DWORD protection, worker_result;
    SIZE_T written = 0;
    HANDLE thread;
    int before = 0, after;
    _Static_assert(sizeof(entry) == sizeof(page), "x64 address size");
    if (!page) return 2;
    memcpy(page, code, sizeof(code));
    memcpy(&entry, &page, sizeof(entry));
    if (!VirtualProtect(page, 4096, execution_protection, &protection) ||
        !FlushInstructionCache(GetCurrentProcess(), page, sizeof(code))) return 2;
    ready = CreateEventW(NULL, TRUE, FALSE, NULL);
    proceed = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!ready || !proceed) return 2;
    for (unsigned i = 0; i < 1000; ++i) before = entry();
    thread = CreateThread(NULL, 0, worker, NULL, 0, NULL);
    if (!thread) return 2;
    if (WaitForSingleObject(ready, 5000) != WAIT_OBJECT_0) return 2;
    if (!WriteProcessMemory(GetCurrentProcess(), (unsigned char *)page + 1,
                            &replacement, sizeof(replacement), &written) || written != 1 ||
        !FlushInstructionCache(GetCurrentProcess(), page, sizeof(code))) return 2;
    printf("readback immediate=%u\n", (unsigned)*(volatile unsigned char *)((unsigned char *)page + 1));
    if (*(volatile unsigned char *)((unsigned char *)page + 1) != replacement) return 2;
    if (explicit_transition &&
        (!VirtualProtect(page, 4096, PAGE_READWRITE, &protection) ||
         !VirtualProtect(page, 4096, execution_protection, &protection))) return 2;
    after = entry();
    if (!SetEvent(proceed) || WaitForSingleObject(thread, 5000) != WAIT_OBJECT_0 ||
        !GetExitCodeThread(thread, &worker_result)) return 2;
    printf("main warm=%d after_write=%d worker_result=%lu\n",
           before, after, (unsigned long)worker_result);
    if (!CloseHandle(thread) || !CloseHandle(ready) || !CloseHandle(proceed) ||
        !VirtualFree(page, 0, MEM_RELEASE)) return 2;
    return before == 1 && after == 2 && worker_result == 0 ? 0 : 1;
}

int main(void)
{
    const struct { DWORD initial, execution; BOOL transition; const char *name; } cases[] = {
        { PAGE_READWRITE, PAGE_EXECUTE_READ, FALSE, "RW to RX" },
        { PAGE_READWRITE, PAGE_EXECUTE_READWRITE, FALSE, "RW to RWX" },
        { PAGE_EXECUTE_READWRITE, PAGE_EXECUTE_READWRITE, FALSE, "RWX to RWX" },
        { PAGE_READWRITE, PAGE_EXECUTE_READWRITE, TRUE, "RW to RWX explicit protection transition" }
    };
    unsigned i, failures = 0;
    for (i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i)
    {
        int result;
        printf("CASE %s initial=%lx execution=%lx\n", cases[i].name,
               (unsigned long)cases[i].initial, (unsigned long)cases[i].execution);
        result = run_case(cases[i].initial, cases[i].execution, cases[i].transition);
        if (result == 2) { puts("ERROR incomplete infrastructure"); return 2; }
        if (result) ++failures;
        printf("VERDICT %s %s\n", cases[i].name, result ? "FAIL" : "PASS");
    }
    printf("SUMMARY cases=4 failures=%u\n", failures);
    return failures ? 1 : 0;
}

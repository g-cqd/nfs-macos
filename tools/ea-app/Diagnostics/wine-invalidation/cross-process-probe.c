#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if !defined(__x86_64__)
#error This probe requires an x86-64 Windows target.
#endif

typedef int (*entry_fn)(void);
struct packet {
    uint32_t magic, phase;
    uintptr_t address;
    DWORD allocation_protect, current_protect;
    int execution_value;
    unsigned immediate;
};
static unsigned checks, failures;

static void check(BOOL passed, const char *name)
{
    ++checks;
    failures += !passed;
    printf("%s %s\n", passed ? "PASS" : "FAIL", name);
}

static BOOL send_packet(HANDLE pipe, struct packet *packet, unsigned char *page,
                        uint32_t phase, int value)
{
    MEMORY_BASIC_INFORMATION info;
    DWORD written;
    if (VirtualQuery(page, &info, sizeof(info)) != sizeof(info)) return FALSE;
    *packet = (struct packet){0x524f5345, phase, (uintptr_t)page,
        info.AllocationProtect, info.Protect, value, *(volatile unsigned char *)(page + 1)};
    return WriteFile(pipe, packet, sizeof(*packet), &written, NULL) && written == sizeof(*packet);
}

static BOOL receive_packet(HANDLE pipe, struct packet *packet, uint32_t phase)
{
    DWORD received;
    return ReadFile(pipe, packet, sizeof(*packet), &received, NULL) && received == sizeof(*packet) &&
        packet->magic == 0x524f5345 && packet->phase == phase && packet->address != 0 &&
        !(packet->address & 0xfff) && packet->address <= UINTPTR_MAX - 4096;
}

static HANDLE parse_handle(const char *text)
{
    char *end;
    unsigned long long value;
    errno = 0;
    value = strtoull(text, &end, 16);
    if (errno || !*text || *end || !value || value > UINTPTR_MAX || value == UINTPTR_MAX) return NULL;
    return (HANDLE)(uintptr_t)value;
}

static int child(HANDLE pipe, HANDLE ready, HANDLE proceed)
{
    /* This process owns the page for its entire lifetime; IPC transfers only its address. */
    const unsigned char code[] = {0xb8, 1, 0, 0, 0, 0xc3};
    unsigned char *page = VirtualAlloc(NULL, 4096, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    entry_fn entry;
    struct packet packet;
    DWORD previous;
    int value = 0, result = 2;
    if (!page) goto done;
    memcpy(page, code, sizeof(code));
    _Static_assert(sizeof(entry) == sizeof(page), "x64 function pointer size");
    memcpy(&entry, &page, sizeof(entry));
    if (!VirtualProtect(page, 4096, PAGE_EXECUTE_READWRITE, &previous) ||
        !FlushInstructionCache(GetCurrentProcess(), page, sizeof(code))) goto done;
    for (unsigned i = 0; i < 1000; ++i)
    {
        value = entry();
        if (value != 1) goto done;
    }
    if (!send_packet(pipe, &packet, page, 1, value) || !SetEvent(ready)) goto done;
    /* No instruction on this page runs between readiness and the parent's release. */
    if (WaitForSingleObject(proceed, 10000) != WAIT_OBJECT_0) goto done;
    value = entry();
    if (!send_packet(pipe, &packet, page, 2, value)) goto done;
    result = 0;
done:
    if (page && !VirtualFree(page, 0, MEM_RELEASE)) result = 2;
    if (!CloseHandle(pipe) || !CloseHandle(ready) || !CloseHandle(proceed)) result = 2;
    return result;
}

static int parent(void)
{
    SECURITY_ATTRIBUTES security = {sizeof(security), NULL, TRUE};
    STARTUPINFOEXA startup;
    PROCESS_INFORMATION process;
    HANDLE read_pipe = NULL, write_pipe = NULL, ready = NULL, proceed = NULL;
    HANDLE inherited[3];
    SIZE_T attributes_size = 0, written = 0;
    struct packet before, after;
    char executable[2048], command[2304];
    DWORD path_length, child_exit, wait_result;
    BOOL started = FALSE, attributes_ready = FALSE, wrote, flushed;
    unsigned char replacement = 2;
    int command_length, result = 2;
    memset(&startup, 0, sizeof(startup));
    memset(&process, 0, sizeof(process));
    startup.StartupInfo.cb = sizeof(startup);
    if (!CreatePipe(&read_pipe, &write_pipe, &security, 0) ||
        !SetHandleInformation(read_pipe, HANDLE_FLAG_INHERIT, 0)) goto done;
    ready = CreateEventW(&security, TRUE, FALSE, NULL);
    proceed = CreateEventW(&security, TRUE, FALSE, NULL);
    if (!ready || !proceed) goto done;
    inherited[0] = write_pipe; inherited[1] = ready; inherited[2] = proceed;
    InitializeProcThreadAttributeList(NULL, 1, 0, &attributes_size);
    if (!attributes_size || attributes_size > 4096) goto done;
    startup.lpAttributeList = HeapAlloc(GetProcessHeap(), 0, attributes_size);
    if (!startup.lpAttributeList ||
        !InitializeProcThreadAttributeList(startup.lpAttributeList, 1, 0, &attributes_size)) goto done;
    attributes_ready = TRUE;
    if (!UpdateProcThreadAttribute(startup.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                                  inherited, sizeof(inherited), NULL, NULL)) goto done;
    path_length = GetModuleFileNameA(NULL, executable, sizeof(executable));
    if (!path_length || path_length >= sizeof(executable) || strchr(executable, '"')) goto done;
    command_length = snprintf(command, sizeof(command), "\"%s\" --child %llx %llx %llx", executable,
        (unsigned long long)(uintptr_t)write_pipe, (unsigned long long)(uintptr_t)ready,
        (unsigned long long)(uintptr_t)proceed);
    if (command_length < 0 || (size_t)command_length >= sizeof(command)) goto done;
    if (!CreateProcessA(executable, command, NULL, NULL, TRUE, EXTENDED_STARTUPINFO_PRESENT,
                        NULL, NULL, &startup.StartupInfo, &process)) goto done;
    started = TRUE;
    if (!CloseHandle(write_pipe)) goto done;
    write_pipe = NULL;
    if (WaitForSingleObject(ready, 10000) != WAIT_OBJECT_0 ||
        !receive_packet(read_pipe, &before, 1)) goto done;
    check(before.execution_value == 1 && before.immediate == 1 &&
          before.allocation_protect == PAGE_READWRITE && before.current_protect == PAGE_EXECUTE_READWRITE,
          "child warmed RW allocation with current RWX protection");
    wrote = WriteProcessMemory(process.hProcess, (void *)(before.address + 1), &replacement, 1, &written);
    flushed = FlushInstructionCache(process.hProcess, (void *)before.address, 6);
    printf("parent write=%u written=%llu flush=%u\n", (unsigned)wrote,
           (unsigned long long)written, (unsigned)flushed);
    check(wrote && written == 1 && flushed, "remote write and flush report success");
    if (!SetEvent(proceed)) goto done;
    wait_result = WaitForSingleObject(process.hProcess, 10000);
    if (wait_result != WAIT_OBJECT_0 || !GetExitCodeProcess(process.hProcess, &child_exit) || child_exit != 0 ||
        !receive_packet(read_pipe, &after, 2) || after.address != before.address) goto done;
    printf("child immediate=%u execution=%d allocation=%lx protection=%lx\n", after.immediate,
           after.execution_value, (unsigned long)after.allocation_protect, (unsigned long)after.current_protect);
    check(after.immediate == 2, "child observes changed instruction byte");
    check(after.allocation_protect == PAGE_READWRITE && after.current_protect == PAGE_EXECUTE_READWRITE,
          "remote invalidation preserves child protection");
    check(after.execution_value == 2, "child executes updated warmed code");
    result = failures ? 1 : 0;
done:
    if (result == 2) printf("INFRA incomplete child protocol error=%lu\n", (unsigned long)GetLastError());
    if (started)
    {
        if (WaitForSingleObject(process.hProcess, 0) != WAIT_OBJECT_0)
        {
            if (!TerminateProcess(process.hProcess, 2) ||
                WaitForSingleObject(process.hProcess, 5000) != WAIT_OBJECT_0) result = 2;
        }
        if (!CloseHandle(process.hThread) || !CloseHandle(process.hProcess)) result = 2;
    }
    if (attributes_ready) DeleteProcThreadAttributeList(startup.lpAttributeList);
    if (startup.lpAttributeList && !HeapFree(GetProcessHeap(), 0, startup.lpAttributeList)) result = 2;
    if (read_pipe && !CloseHandle(read_pipe)) result = 2;
    if (write_pipe && !CloseHandle(write_pipe)) result = 2;
    if (ready && !CloseHandle(ready)) result = 2;
    if (proceed && !CloseHandle(proceed)) result = 2;
    printf("SUMMARY checks=%u failures=%u infrastructure=%u\n", checks, failures, result == 2);
    return result;
}

int main(int argc, char **argv)
{
    if (argc == 1) return parent();
    if (argc == 5 && !strcmp(argv[1], "--child"))
    {
        HANDLE pipe = parse_handle(argv[2]), ready = parse_handle(argv[3]), proceed = parse_handle(argv[4]);
        if (pipe && ready && proceed) return child(pipe, ready, proceed);
    }
    return 2;
}

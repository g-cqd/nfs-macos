/*
 * Execution-breakpoint contract tests using only this executable's fixtures.
 * Guest-TF ordering follows Wine's ntdll/tests/exception.c bpx_handler test.
 * Wine test suite copyright 2005 Alexandre Julliard.
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winternl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#if !defined(__x86_64__)
#error This probe requires Windows x64.
#endif

#define TF_BIT UINT32_C(0x100)
#define RF_BIT UINT32_C(0x10000)
#define REASON_MASK UINT64_C(0x400f)
#define MAX_EVENTS 16u

extern DWORD WINAPI plain_fixture(void *argument);
extern DWORD WINAPI busy_fixture(void *argument);
extern DWORD WINAPI rf_fixture(void *argument);
extern DWORD WINAPI guest_fixture(void *argument);
extern DWORD WINAPI flags_fixture(void *argument);
extern DWORD WINAPI flags_set_fixture(void *argument);
extern const unsigned char plain_end, busy_loop, busy_end;
extern const unsigned char rf_setup, rf_entry, rf_end;
extern const unsigned char guest_setup, guest_entry, guest_second, guest_third, guest_end;
extern const unsigned char flags_setup, flags_entry, flags_target, flags_end;
extern const unsigned char flags_set_setup, flags_set_entry, flags_set_target, flags_set_end;

/* The worker owns fixture writes; the parent reads only after joining it. */
volatile LONG entered;
volatile LONG release_gate;
volatile uint64_t observed_flags;

enum scenario { INITIAL, DISABLED, REMOTE_USER, REMOTE_SYSCALL, RF, GUEST_TF, FLAGS, FLAGS_SET };
static const char *const scenario_names[] = {
    "initial", "disabled", "remote-user", "remote-syscall", "rf", "guest-tf", "flags", "flags-set"
};
static enum scenario scenario;
static DWORD worker_id;
static HANDLE ready_event, go_event;
static uintptr_t wait_entry;
static volatile unsigned setup_count, event_count;
static unsigned checks, failures;

struct trap_event {
    uintptr_t instruction, address;
    uint64_t dr6;
    DWORD flags;
    LONG entered_before;
};
static volatile struct trap_event events[MAX_EVENTS];

static void expect(const char *name, BOOL condition)
{
    ++checks;
    if (!condition) ++failures;
    printf("%s %s\n", condition ? "PASS" : "FAIL", name);
}

static BOOL in_range(uintptr_t instruction, uintptr_t begin, uintptr_t end)
{
    return instruction >= begin && instruction < end;
}

static BOOL own_instruction(uintptr_t instruction)
{
    return in_range(instruction, (uintptr_t)&plain_fixture, (uintptr_t)&plain_end) ||
           in_range(instruction, (uintptr_t)&busy_fixture, (uintptr_t)&busy_end) ||
           in_range(instruction, (uintptr_t)&rf_fixture, (uintptr_t)&rf_end) ||
           in_range(instruction, (uintptr_t)&guest_fixture, (uintptr_t)&guest_end) ||
           in_range(instruction, (uintptr_t)&flags_fixture, (uintptr_t)&flags_end) ||
           in_range(instruction, (uintptr_t)&flags_set_fixture, (uintptr_t)&flags_set_end);
}

static LONG CALLBACK handler(EXCEPTION_POINTERS *exception)
{
    CONTEXT *context = exception->ContextRecord;
    EXCEPTION_RECORD *record = exception->ExceptionRecord;
    uintptr_t setup = 0, entry = 0, target = 0;
    unsigned index;

    if (GetCurrentThreadId() != worker_id) return EXCEPTION_CONTINUE_SEARCH;
    if (scenario == RF) {
        setup = (uintptr_t)&rf_setup;
        entry = target = (uintptr_t)&rf_entry;
    } else if (scenario == GUEST_TF) {
        setup = (uintptr_t)&guest_setup;
        entry = target = (uintptr_t)&guest_entry;
    } else if (scenario == FLAGS) {
        setup = (uintptr_t)&flags_setup;
        entry = (uintptr_t)&flags_entry;
        target = (uintptr_t)&flags_target;
    } else if (scenario == FLAGS_SET) {
        setup = (uintptr_t)&flags_set_setup;
        entry = (uintptr_t)&flags_set_entry;
        target = (uintptr_t)&flags_set_target;
    }
    if (record->ExceptionCode == EXCEPTION_BREAKPOINT && setup &&
        (uintptr_t)record->ExceptionAddress == setup) {
        if (setup_count++) return EXCEPTION_CONTINUE_SEARCH;
        /* INT3 provides an owned context boundary without stepping startup code. */
        context->Rip = entry;
        context->Dr0 = target;
        context->Dr1 = context->Dr2 = context->Dr3 = context->Dr6 = 0;
        context->Dr7 = 1;
        context->EFlags &= ~(TF_BIT | RF_BIT);
        if (scenario == RF) context->EFlags |= RF_BIT;
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    if (record->ExceptionCode != EXCEPTION_SINGLE_STEP ||
        !own_instruction((uintptr_t)context->Rip)) return EXCEPTION_CONTINUE_SEARCH;
    index = event_count;
    if (index >= MAX_EVENTS) return EXCEPTION_CONTINUE_SEARCH;
    events[index].instruction = (uintptr_t)context->Rip;
    events[index].address = (uintptr_t)record->ExceptionAddress;
    events[index].dr6 = context->Dr6;
    events[index].flags = context->EFlags;
    events[index].entered_before = InterlockedCompareExchange(&entered, 0, 0);
    event_count = index + 1;
    context->Dr6 = 0;
    context->EFlags &= ~TF_BIT;
    if (scenario == GUEST_TF && index < 3) {
        context->EFlags |= TF_BIT;
        if (index == 0) context->Dr0 = (uintptr_t)&guest_second;
        if (index == 2) context->Dr7 = 0;
    } else if (scenario == FLAGS_SET && index == 0) {
        /* Preserve the pending execution breakpoint after delivering guest BS. */
        context->Dr7 = 1;
    } else context->Dr7 = 0;
    return EXCEPTION_CONTINUE_EXECUTION;
}

static LONG WINAPI unhandled(EXCEPTION_POINTERS *exception)
{
    printf("ERROR unhandled code=%08lx rip=%016" PRIx64 "\n",
           (unsigned long)exception->ExceptionRecord->ExceptionCode,
           (uint64_t)exception->ContextRecord->Rip);
    fflush(stdout);
    ExitProcess(3);
    return EXCEPTION_EXECUTE_HANDLER;
}

static DWORD WINAPI remote_worker(void *argument)
{
    (void)argument;
    if (!SetEvent(ready_event)) return 78;
    if (scenario == REMOTE_USER) return busy_fixture(NULL);
    if (NtWaitForSingleObject(go_event, FALSE, NULL)) return 79;
    return plain_fixture(NULL);
}

static BOOL install_debug(HANDLE thread, BOOL enabled)
{
    CONTEXT context = {0};
    context.ContextFlags = CONTEXT_DEBUG_REGISTERS;
    context.Dr0 = (uintptr_t)&plain_fixture;
    context.Dr7 = enabled ? 1 : 0;
    if (!SetThreadContext(thread, &context)) return FALSE;
    memset(&context, 0, sizeof(context));
    context.ContextFlags = CONTEXT_DEBUG_REGISTERS;
    if (!GetThreadContext(thread, &context)) return FALSE;
    expect("configured DR0 and DR7 read back", context.Dr0 == (uintptr_t)&plain_fixture &&
           (context.Dr7 & 0xff) == (enabled ? 1 : 0));
    return TRUE;
}

static BOOL arm_remote(HANDLE thread)
{
    CONTEXT context;
    for (unsigned i = 0; i < 32; ++i) {
        BOOL desired;
        if (SuspendThread(thread) == (DWORD)-1) return FALSE;
        memset(&context, 0, sizeof(context));
        context.ContextFlags = CONTEXT_CONTROL | CONTEXT_EXCEPTION_REQUEST;
        if (!GetThreadContext(thread, &context)) {
            ResumeThread(thread);
            return FALSE;
        }
        if (scenario == REMOTE_USER)
            desired = in_range((uintptr_t)context.Rip, (uintptr_t)&busy_fixture,
                               (uintptr_t)&busy_end) && !(context.ContextFlags & CONTEXT_SERVICE_ACTIVE);
        else
            /* After ready_event, this worker's only call is NtWaitForSingleObject. */
            desired = (context.ContextFlags & CONTEXT_SERVICE_ACTIVE) &&
                      in_range((uintptr_t)context.Rip, wait_entry, wait_entry + 64);
        if (desired) {
            BOOL installed = install_debug(thread, TRUE);
            printf("PROBE remote_context=%s flags=%08lx rip=%016" PRIx64
                   " wait_entry=%016" PRIxPTR "\n", scenario_names[scenario],
                   (unsigned long)context.ContextFlags, (uint64_t)context.Rip, wait_entry);
            if (ResumeThread(thread) == (DWORD)-1) return FALSE;
            return installed;
        }
        if (ResumeThread(thread) == (DWORD)-1) return FALSE;
        SwitchToThread();
    }
    return FALSE;
}

int main(int argc, char **argv)
{
    LPTHREAD_START_ROUTINE entry = plain_fixture;
    HANDLE thread = NULL;
    PVOID registration = NULL;
    DWORD exit_code = 0;
    BOOL prepared = TRUE;
    uintptr_t expected = (uintptr_t)&plain_fixture;
    unsigned selected;

    if (argc != 2) return 2;
    for (selected = 0; selected < sizeof(scenario_names) / sizeof(scenario_names[0]); ++selected)
        if (!strcmp(argv[1], scenario_names[selected])) break;
    if (selected == sizeof(scenario_names) / sizeof(scenario_names[0])) return 2;
    scenario = (enum scenario)selected;
    printf("PROBE case=%s own-code execution-breakpoint contract\n", scenario_names[scenario]);
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
    SetUnhandledExceptionFilter(unhandled);
    registration = AddVectoredExceptionHandler(1, handler);
    if (!registration) goto infrastructure;
    if (scenario == REMOTE_SYSCALL) {
        FARPROC wait_function = GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtWaitForSingleObject");
        if (!wait_function) goto infrastructure;
        wait_entry = (uintptr_t)wait_function;
    }
    if (scenario == REMOTE_USER || scenario == REMOTE_SYSCALL) {
        ready_event = CreateEventW(NULL, TRUE, FALSE, NULL);
        go_event = CreateEventW(NULL, TRUE, FALSE, NULL);
        if (!ready_event || !go_event) goto infrastructure;
        entry = remote_worker;
    } else if (scenario == RF) entry = rf_fixture;
    else if (scenario == GUEST_TF) entry = guest_fixture;
    else if (scenario == FLAGS) entry = flags_fixture;
    else if (scenario == FLAGS_SET) entry = flags_set_fixture;

    thread = CreateThread(NULL, 0, entry, NULL, CREATE_SUSPENDED, &worker_id);
    if (!thread) goto infrastructure;
    if (scenario == INITIAL || scenario == DISABLED) {
        prepared = install_debug(thread, TRUE);
        if (prepared && scenario == DISABLED) prepared = install_debug(thread, FALSE);
    }
    if (!prepared || ResumeThread(thread) == (DWORD)-1) goto infrastructure;
    if (scenario == REMOTE_USER || scenario == REMOTE_SYSCALL) {
        if (WaitForSingleObject(ready_event, 5000) != WAIT_OBJECT_0 || !arm_remote(thread))
            goto infrastructure;
        InterlockedExchange(&release_gate, 1);
        if (!SetEvent(go_event)) goto infrastructure;
    }
    if (WaitForSingleObject(thread, 5000) != WAIT_OBJECT_0 || !GetExitCodeThread(thread, &exit_code))
        goto infrastructure;
    expect("worker returns normally with 66", exit_code == 66);
    expect("fixture executes the expected number of times", entered == (scenario == RF ? 2 : 1));
    if (scenario == RF || scenario == GUEST_TF || scenario == FLAGS || scenario == FLAGS_SET)
        expect("exactly one owned INT3 setup boundary", setup_count == 1);
    expect("expected number of debug exceptions",
           event_count == (scenario == DISABLED ? 0u : scenario == GUEST_TF ? 4u : scenario == FLAGS_SET ? 2u : 1u));

    if (scenario == RF) expected = (uintptr_t)&rf_entry;
    if (scenario == FLAGS) expected = (uintptr_t)&flags_target;
    for (unsigned i = 0; i < event_count && i < MAX_EVENTS; ++i)
        printf("EVENT index=%u rip=%016" PRIxPTR " address=%016" PRIxPTR
               " dr6=%016" PRIx64 " flags=%08lx entered_before=%ld\n", i,
               events[i].instruction, events[i].address, events[i].dr6,
               (unsigned long)events[i].flags, (long)events[i].entered_before);
    if (scenario != DISABLED && scenario != GUEST_TF && scenario != FLAGS_SET) {
        expect("breakpoint reports exact instruction before its effect",
               event_count == 1 && events[0].instruction == expected &&
               events[0].address == expected && events[0].entered_before == (scenario == RF ? 1 : 0));
        expect("breakpoint reports B0 without internal BS", event_count == 1 &&
               (events[0].dr6 & REASON_MASK) == 1);
        expect("internal TF is absent from delivered context", event_count == 1 &&
               !(events[0].flags & TF_BIT));
    }
    if (scenario == GUEST_TF) {
        const uintptr_t instructions[4] = {
            (uintptr_t)&guest_entry, (uintptr_t)&guest_second,
            (uintptr_t)&guest_second, (uintptr_t)&guest_third
        };
        BOOL ordered = event_count == 4;
        for (unsigned i = 0; i < event_count && i < 4; ++i)
            if (events[i].instruction != instructions[i] || events[i].address != instructions[i] ||
                (events[i].dr6 & REASON_MASK) != (i % 2 ? UINT64_C(0x4000) : UINT64_C(1)) ||
                (events[i].flags & TF_BIT)) ordered = FALSE;
        expect("guest BS and execution B0 retain separate ordered events", ordered);
    }
    if (scenario == FLAGS)
        expect("PUSHFQ observes guest TF clear while breakpoint remains enabled", !(observed_flags & TF_BIT));
    if (scenario == FLAGS_SET) {
        BOOL ordered = event_count == 2;
        for (unsigned i = 0; i < event_count && i < 2; ++i)
            if (events[i].instruction != (uintptr_t)&flags_set_target ||
                events[i].address != (uintptr_t)&flags_set_target || events[i].entered_before != 0 ||
                (events[i].dr6 & REASON_MASK) != (i == 0 ? UINT64_C(0x4000) : UINT64_C(1)) ||
                (events[i].flags & TF_BIT)) ordered = FALSE;
        expect("POPFQ guest step precedes execution breakpoint at the same RIP", ordered);
        expect("PUSHFQ sees TF clear before the guest sets it", !(observed_flags & TF_BIT));
    }

    if (!CloseHandle(thread) || !RemoveVectoredExceptionHandler(registration)) goto infrastructure;
    if (ready_event) CloseHandle(ready_event);
    if (go_event) CloseHandle(go_event);
    printf("SUMMARY checks=%u failures=%u events=%u setups=%u\n", checks, failures, event_count, setup_count);
    return failures ? 1 : 0;

infrastructure:
    printf("ERROR infrastructure case=%s winerror=%lu\n", scenario_names[scenario],
           (unsigned long)GetLastError());
    fflush(stdout);
    /* Process exit also ends any exclusively owned worker left suspended. */
    ExitProcess(2);
    return 2;
}

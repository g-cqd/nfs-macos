#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>

#if !defined(__x86_64__)
#error This probe requires x86-64 Windows.
#endif

extern void ordinary_entry(void), flags_entry(void), clear_entry(void), ss_entry(void);
extern void syscall_entry(void);
extern char ordinary_start, ordinary_a, ordinary_b, ordinary_c, ordinary_end;
extern char flags_start, flags_a, flags_b, flags_end;
extern char clear_start, clear_a, clear_b, clear_c, clear_d, clear_end;
extern char ss_start, ss_a, ss_b, ss_c, ss_end;
extern char syscall_start, syscall_call, syscall_after, syscall_end;
extern LONG WINAPI NtYieldExecution(void);
LONG (WINAPI *yield_function)(void) = NtYieldExecution;
volatile DWORD64 captured_flags;

#define LABEL(x) ".globl " #x "\n" #x ": "
__asm__(".text\n.p2align 4\n"
        LABEL(ordinary_entry) "int3\n"
        LABEL(ordinary_start) "nop\n"
        LABEL(ordinary_a) "xor %eax,%eax\n"
        LABEL(ordinary_b) "jmp ordinary_c\n"
        "ud2\n"
        LABEL(ordinary_c) "nop\n"
        LABEL(ordinary_end) "int3\nret\n"
        LABEL(flags_entry) "int3\n"
        LABEL(flags_start) "pushfq\n"
        LABEL(flags_a) "pop %rax\n"
        LABEL(flags_b) "mov %rax,captured_flags(%rip)\n"
        LABEL(flags_end) "int3\nret\n"
        LABEL(clear_entry) "int3\n"
        LABEL(clear_start) "pushfq\n"
        LABEL(clear_a) "andq $-257,(%rsp)\n"
        LABEL(clear_b) "popfq\n"
        LABEL(clear_c) "nop\n"
        LABEL(clear_d) "nop\n"
        LABEL(clear_end) "int3\nret\n"
        LABEL(ss_entry) "int3\n"
        LABEL(ss_start) "mov %ss,%ax\n"
        LABEL(ss_a) "mov %ax,%ss\n"
        LABEL(ss_b) "nop\n"
        LABEL(ss_c) "nop\n"
        LABEL(ss_end) "int3\nret\n"
        LABEL(syscall_entry) "int3\n"
        LABEL(syscall_start) "sub $40,%rsp\n"
        LABEL(syscall_call) "call *yield_function(%rip)\n"
        LABEL(syscall_after) "add $40,%rsp\n"
        LABEL(syscall_end) "int3\nret\n");

struct test_case
{
    const char *name;
    void (*entry)(void);
    const char *start, *end;
    const char *expected[8];
    unsigned expected_count;
    BOOL permit_external_steps;
};

static const struct test_case cases[] =
{
    { "ordinary", ordinary_entry, &ordinary_start, &ordinary_end,
      { &ordinary_a, &ordinary_b, &ordinary_c, &ordinary_end }, 4, FALSE },
    { "pushfq", flags_entry, &flags_start, &flags_end,
      { &flags_a, &flags_b, &flags_end }, 3, FALSE },
    { "popfq-clear", clear_entry, &clear_start, &clear_end,
      { &clear_a, &clear_b, &clear_c, &clear_d, &clear_end }, 5, FALSE },
    { "mov-ss", ss_entry, &ss_start, &ss_end,
      /* Intel SDM Vol. 3A 7.8.3 suppresses TF delivery after loading SS. */
      { &ss_a, &ss_c, &ss_end }, 3, FALSE },
    { "syscall-return", syscall_entry, &syscall_start, &syscall_end,
      { &syscall_call, &syscall_after, &syscall_end }, 3, TRUE }
};

/* One executing thread owns this fixed storage throughout each handler lifetime. */
static const struct test_case *current;
static DWORD owner;
static unsigned count, begun, ended, overflow, unexpected, external_steps;
static unsigned tf_visibility_failures;
static DWORD64 seen[32];
static BOOL stepping;

static LONG CALLBACK handler(EXCEPTION_POINTERS *exception)
{
    CONTEXT *context = exception->ContextRecord;
    DWORD code = exception->ExceptionRecord->ExceptionCode;
    uintptr_t address = (uintptr_t)exception->ExceptionRecord->ExceptionAddress;
    if (GetCurrentThreadId() != owner || !current) return EXCEPTION_CONTINUE_SEARCH;
    if (code == EXCEPTION_BREAKPOINT && address == (uintptr_t)current->entry && !begun)
    {
        begun = 1;
        context->Rip = (DWORD64)(uintptr_t)current->start;
        if (stepping) context->EFlags |= 0x100;
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    if (code == EXCEPTION_BREAKPOINT && address == (uintptr_t)current->end && begun && !ended)
    {
        ended = 1;
        context->Rip = (DWORD64)(uintptr_t)current->end + 1;
        context->EFlags &= ~0x100UL;
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    if (code == EXCEPTION_SINGLE_STEP && stepping && begun && !ended)
    {
        if (context->Dr6 & 0xf) return EXCEPTION_CONTINUE_SEARCH;
        if (current->permit_external_steps &&
            (context->Rip < (DWORD64)(uintptr_t)current->start ||
             context->Rip > (DWORD64)(uintptr_t)current->end))
        {
            if (++external_steps > 4096)
            {
                overflow = 1;
                context->EFlags &= ~0x100UL;
            }
            else context->EFlags |= 0x100;
            return EXCEPTION_CONTINUE_EXECUTION;
        }
        if (count == sizeof(seen) / sizeof(seen[0]))
        {
            overflow = 1;
            context->EFlags &= ~0x100UL;
            return EXCEPTION_CONTINUE_EXECUTION;
        }
        seen[count++] = context->Rip;
        if (address != context->Rip) unexpected = 1;
        if (context->Rip == (DWORD64)(uintptr_t)current->end) context->EFlags &= ~0x100UL;
        else context->EFlags |= 0x100;
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    return EXCEPTION_CONTINUE_SEARCH;
}

static int run_case(const struct test_case *test, BOOL enable, const char *phase)
{
    unsigned i;
    int exact;
    current = test;
    stepping = enable;
    begun = ended = count = overflow = unexpected = external_steps = 0;
    captured_flags = 0;
    test->entry();
    current = NULL;
    exact = begun && ended && !overflow && !unexpected;
    if (enable)
    {
        exact = exact && count == test->expected_count;
        for (i = 0; i < count && i < test->expected_count; ++i)
            exact = exact && seen[i] == (DWORD64)(uintptr_t)test->expected[i];
    }
    else exact = exact && count == 0;
    printf("%s %s stepping=%d boundaries=%u/%u exact=%d pushed_TF=%d external_steps=%u\n",
           phase, test->name, enable, count, enable ? test->expected_count : 0,
           exact, !!(captured_flags & 0x100), external_steps);
    for (i = 0; i < count; ++i)
        printf("  boundary[%u] offset=%lld\n", i,
               (long long)(seen[i] - (DWORD64)(uintptr_t)test->start));
    return !exact;
}

static int run_cases(const char *phase)
{
    unsigned i;
    int failures = 0;
    owner = GetCurrentThreadId();
    for (i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i)
    {
        DWORD64 stepped_flags;
        failures += run_case(&cases[i], TRUE, phase);
        stepped_flags = captured_flags;
        failures += run_case(&cases[i], FALSE, phase);
        if (cases[i].entry == flags_entry)
        {
            BOOL visible = (stepped_flags & 0x100) && !(captured_flags & 0x100);
            printf("%s architectural-TF visible-through-PUSHFQ=%s\n", phase, visible ? "PASS" : "FAIL");
            if (!visible) ++tf_visibility_failures;
        }
    }
    return failures;
}

static DWORD WINAPI worker(void *unused)
{
    (void)unused;
    return (DWORD)run_cases("worker warm");
}

int main(void)
{
    int failures;
    HANDLE thread;
    DWORD result;
    PVOID registration = AddVectoredExceptionHandler(1, handler);
    if (!registration) return 2;
    failures = run_cases("main cold");
    failures += run_cases("main warm");
    thread = CreateThread(NULL, 0, worker, NULL, 0, NULL);
    if (!thread || WaitForSingleObject(thread, 10000) != WAIT_OBJECT_0) return 2;
    if (!GetExitCodeThread(thread, &result) || !CloseHandle(thread)) return 2;
    if (!RemoveVectoredExceptionHandler(registration)) return 2;
    failures += result;
    printf("SUMMARY boundary_cases=30 exact_boundary_failures=%d TF_visibility_cases=3 TF_visibility_failures=%u\n",
           failures, tf_visibility_failures);
    return failures || tf_visibility_failures ? 1 : 0;
}

/* Safe DEBUG state checks: the enabled address belongs to code that is never called. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>

static unsigned checks, failures;

static DWORD WINAPI unused_target(void *argument)
{
    (void)argument;
    return 97;
}

static void expect(const char *name, BOOL condition)
{
    ++checks;
    if (!condition) ++failures;
    printf("%s %s\n", condition ? "PASS" : "FAIL", name);
}

static BOOL read_state(HANDLE thread, DWORD dr6, DWORD dr7)
{
    CONTEXT context = {0};
    context.ContextFlags = CONTEXT_DEBUG_REGISTERS;
    return GetThreadContext(thread, &context) &&
           context.Dr0 == (DWORD_PTR)&unused_target &&
           (context.Dr6 & 0x400f) == dr6 && (context.Dr7 & 0xff) == dr7;
}

int main(void)
{
    HANDLE alias, duplicate = NULL;
    CONTEXT context = {0};
    BOOL first_set, first_pseudo, first_alias, first_duplicate, second_set, second_pseudo;
    BOOL cleared, clear_read;
    alias = OpenThread(THREAD_GET_CONTEXT | THREAD_SET_CONTEXT, FALSE, GetCurrentThreadId());
    if (!alias || !DuplicateHandle(GetCurrentProcess(), alias, GetCurrentProcess(),
                                   &duplicate, 0, FALSE, DUPLICATE_SAME_ACCESS)) {
        printf("ERROR self alias setup failed\n");
        if (alias) CloseHandle(alias);
        return 2;
    }
    context.ContextFlags = CONTEXT_DEBUG_REGISTERS;
    context.Dr0 = (DWORD_PTR)&unused_target;
    context.Dr6 = 0x4001;
    context.Dr7 = 1;
    first_set = SetThreadContext(GetCurrentThread(), &context);
    first_pseudo = read_state(GetCurrentThread(), 0x4001, 1);
    first_alias = read_state(alias, 0x4001, 1);
    first_duplicate = read_state(duplicate, 0x4001, 1);
    context.Dr6 = 0x4002;
    context.Dr7 = 2;
    second_set = SetThreadContext(alias, &context);
    second_pseudo = read_state(GetCurrentThread(), 0x4002, 2);
    context.Dr6 = context.Dr7 = 0;
    cleared = SetThreadContext(duplicate, &context);
    clear_read = read_state(GetCurrentThread(), 0, 0);
    /* Reporting happens after disabling the breakpoint; no target instruction runs. */
    printf("PROBE debug state pointer_bits=%u\n", (unsigned)(8 * sizeof(void *)));
    expect("pseudo self enables unused execution address", first_set);
    expect("pseudo self reads DR6 and local enable", first_pseudo);
    expect("real self alias reads DR6 and local enable", first_alias);
    expect("duplicate self alias reads DR6 and local enable", first_duplicate);
    expect("real self alias changes DR6 and global enable", second_set);
    expect("pseudo self reads alias DR6 and global enable", second_pseudo);
    expect("duplicate self alias clears debug status and enables", cleared);
    expect("cleared state reads through pseudo self", clear_read);
    if (!CloseHandle(duplicate) || !CloseHandle(alias)) return 2;
    printf("SUMMARY checks=%u failures=%u\n", checks, failures);
    return failures ? 1 : 0;
}

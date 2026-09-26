#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

extern DWORD WINAPI supplement_fixture(void *argument);
extern const unsigned char supplement_setup, supplement_entry, supplement_target;
extern const unsigned char mask_entry, mask_target, mov_ss_entry, flag16_entry;
extern const unsigned char push_fault_entry, pop_fault_entry, budget_entry, elapsed_entry;
extern const unsigned char visible_entry, visible_after_push, visible_target, icebp_entry;
volatile uint64_t observed_mask;
static const char *selected;
static DWORD worker_id;
static unsigned events;
static uint64_t observed_dr6;
static void *fault_page;
static const unsigned char nx_flags[] = {0x9c, 0xc3};

static LONG CALLBACK handler(EXCEPTION_POINTERS *exception)
{
    CONTEXT *c = exception->ContextRecord;
    if (GetCurrentThreadId() != worker_id) return EXCEPTION_CONTINUE_SEARCH;
    if (exception->ExceptionRecord->ExceptionCode == EXCEPTION_BREAKPOINT &&
        (uintptr_t)exception->ExceptionRecord->ExceptionAddress == (uintptr_t)&supplement_setup) {
        c->Rip = (uintptr_t)&supplement_entry;
        c->Dr0 = (uintptr_t)&supplement_target;
        c->Dr1 = c->Dr2 = c->Dr3 = 0;
        c->Dr6 = !strcmp(selected, "sticky-dr6") ? 0x4000 : 0;
        c->Dr7 = 1;
        c->EFlags &= ~0x10100;
        if (!strcmp(selected, "slot-matches")) {
            c->Dr0 = 0;
            c->Dr1 = c->Dr2 = c->Dr3 = (uintptr_t)&supplement_target;
            c->Dr7 = 0xd8; /* Global slot 1, local slot 2, both enables in slot 3. */
        } else if (!strcmp(selected, "push-rf") || !strcmp(selected, "push-guest-tf")) {
            c->Rip = (uintptr_t)&visible_entry;
            c->Dr0 = (uintptr_t)&visible_target;
            c->EFlags |= !strcmp(selected, "push-rf") ? 0x10000 : 0x100;
        } else if (!strcmp(selected, "flag-mask")) {
            c->Rip = (uintptr_t)&mask_entry;
            c->Dr0 = (uintptr_t)&mask_target;
            /* Try changing arithmetic/DF/ID, IF, IOPL and a reserved bit. TF and NT remain clear. */
            c->Rax = UINT64_C(0x200000) | 0xcd5 | 0x3000 | 8;
        } else if (!strcmp(selected, "mov-ss")) {
            c->Rip = (uintptr_t)&mov_ss_entry;
            c->Rax = c->SegSs;
        } else if (!strcmp(selected, "flag16")) c->Rip = (uintptr_t)&flag16_entry;
        else if (!strcmp(selected, "push-fault")) {
            c->Rip = (uintptr_t)&push_fault_entry;
            c->Rsp = (uintptr_t)fault_page + 8;
        } else if (!strcmp(selected, "pop-fault")) {
            c->Rip = (uintptr_t)&pop_fault_entry;
            c->Rsp = (uintptr_t)fault_page;
        } else if (!strcmp(selected, "icebp")) c->Rip = (uintptr_t)&icebp_entry;
        else if (!strcmp(selected, "nx-flag")) c->Rip = (uintptr_t)nx_flags;
        else if (!strcmp(selected, "budget")) c->Rip = (uintptr_t)&budget_entry;
        else if (!strcmp(selected, "elapsed")) c->Rip = (uintptr_t)&elapsed_entry;
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    if (!strcmp(selected, "push-guest-tf") && !events &&
        exception->ExceptionRecord->ExceptionCode == EXCEPTION_SINGLE_STEP &&
        c->Rip == (uintptr_t)&visible_after_push && (c->Dr6 & 0x400f) == 0x4000) {
        ++events;
        c->Dr6 = 0;
        c->EFlags &= ~0x100;
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    if (exception->ExceptionRecord->ExceptionCode == EXCEPTION_SINGLE_STEP &&
        (c->Rip == (uintptr_t)&supplement_target || c->Rip == (uintptr_t)&mask_target ||
         c->Rip == (uintptr_t)&visible_target) && events == (unsigned)!strcmp(selected, "push-guest-tf")) {
        ++events;
        observed_dr6 = c->Dr6;
        c->Dr6 = c->Dr7 = 0;
        c->EFlags &= ~0x100;
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    return EXCEPTION_CONTINUE_SEARCH;
}

int main(int argc, char **argv)
{
    HANDLE thread;
    PVOID registration;
    DWORD result, code = 0;
    BOOL pass;
    if (argc != 2) return 2;
    selected = argv[1];
    printf("PROBE supplement=%s\n", selected);
    fflush(stdout);
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
    if (strstr(selected, "fault")) {
        fault_page = VirtualAlloc(NULL, 4096, MEM_RESERVE | MEM_COMMIT, PAGE_NOACCESS);
        if (!fault_page) return 2;
    }
    registration = AddVectoredExceptionHandler(1, handler);
    if (!registration) return 2;
    thread = CreateThread(NULL, 0, supplement_fixture, NULL, CREATE_SUSPENDED, &worker_id);
    if (!thread || ResumeThread(thread) == (DWORD)-1) return 2;
    result = WaitForSingleObject(thread, 10000);
    if (result != WAIT_OBJECT_0 || !GetExitCodeThread(thread, &code)) return 2;
    if (!CloseHandle(thread) || !RemoveVectoredExceptionHandler(registration)) return 2;
    if (fault_page && !VirtualFree(fault_page, 0, MEM_RELEASE)) return 2;
    pass = events == (!strcmp(selected, "push-guest-tf") ? 2u : 1u) && code == 66;
    if (!strcmp(selected, "sticky-dr6")) pass = pass && (observed_dr6 & 0x400f) == 0x4001;
    else if (!strcmp(selected, "slot-matches")) pass = pass && (observed_dr6 & 0x400f) == 0xe;
    else if (!strcmp(selected, "push-rf")) pass = pass && (observed_mask & 0x10100) == 0;
    else if (!strcmp(selected, "push-guest-tf")) pass = pass && (observed_mask & 0x10100) == 0x100;
    else if (!strcmp(selected, "flag-mask"))
        pass = pass && (observed_mask & UINT64_C(0x243fdf)) == UINT64_C(0x200ed7);
    else pass = FALSE; /* Every unsupported case must stop before normal completion. */
    printf("%s supplement=%s events=%u dr6=%016" PRIx64 " flags=%016" PRIx64 " code=%lu\n",
           pass ? "PASS" : "FAIL", selected, events, observed_dr6, observed_mask, (unsigned long)code);
    return pass ? 0 : 1;
}

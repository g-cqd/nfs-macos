#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0600
#include <windows.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>

#if !defined(__x86_64__)
#error This probe requires an x86-64 Windows target.
#endif

_Static_assert(_Alignof(CONTEXT) >= 16, "CONTEXT must have x64 alignment");

static unsigned checks;
static unsigned failures;
static unsigned errors;
static volatile LONG target_id;
static volatile LONG handler_hits;
static volatile LONG matching_contexts;
static volatile LONG hits_before_entry;
static volatile LONG worker_entries;
static volatile LONG64 observed_dr6;

static LONG read_counter(volatile LONG *counter)
{
    return InterlockedCompareExchange(counter, 0, 0);
}

static __attribute__((noinline)) DWORD WINAPI worker_main(void *argument)
{
    (void)argument;
    InterlockedIncrement(&worker_entries);
    return 0x42;
}

static DWORD64 worker_address(void)
{
    return (DWORD64)(uintptr_t)worker_main;
}

static LONG CALLBACK breakpoint_handler(EXCEPTION_POINTERS *exception)
{
    CONTEXT *context = exception->ContextRecord;
    const DWORD64 address = worker_address();
    LONG hits;

    if (exception->ExceptionRecord->ExceptionCode != EXCEPTION_SINGLE_STEP ||
        GetCurrentThreadId() != (DWORD)read_counter(&target_id) ||
        (DWORD64)(uintptr_t)exception->ExceptionRecord->ExceptionAddress != address)
        return EXCEPTION_CONTINUE_SEARCH;

    hits = InterlockedIncrement(&handler_hits);
    /* A broken continuation must not cause an unbounded exception loop. */
    if (hits > 2) return EXCEPTION_CONTINUE_SEARCH;
    if (context->Rip == address) InterlockedIncrement(&matching_contexts);
    if (read_counter(&worker_entries) == 0)
        InterlockedIncrement(&hits_before_entry);
    InterlockedExchange64(&observed_dr6, (LONG64)context->Dr6);

    /* Only this probe enables slot zero; clear it before retrying its entry. */
    context->Dr0 = 0;
    context->Dr7 &= ~UINT64_C(3);
    context->Dr6 &= ~UINT64_C(1);
    return EXCEPTION_CONTINUE_EXECUTION;
}

static void api_error(const char *operation, DWORD error)
{
    ++errors;
    printf("ERROR %s winerror=%lu\n", operation, (unsigned long)error);
}

static void expect(const char *name, BOOL passed)
{
    ++checks;
    if (!passed) ++failures;
    printf("%s %s\n", passed ? "PASS" : "FAIL", name);
}

static BOOL join_worker(HANDLE target)
{
    DWORD result = WaitForSingleObject(target, 5000);
    if (result == WAIT_OBJECT_0) return TRUE;
    api_error("join worker", result == WAIT_FAILED ? GetLastError() : ERROR_TIMEOUT);
    return FALSE;
}

int main(void)
{
    PVOID handler = NULL;
    HANDLE target = NULL;
    DWORD id = 0;
    DWORD exit_code = 0;
    BOOL resumed = FALSE;
    BOOL joined = FALSE;
    BOOL waited = FALSE;
    BOOL accepted;
    CONTEXT context = {0};

    puts("execution-breakpoint-probe x64: own suspended worker, DR7=1");
    printf("worker entry=%016" PRIx64 "\n", (uint64_t)worker_address());
    handler = AddVectoredExceptionHandler(1, breakpoint_handler);
    if (!handler) {
        api_error("AddVectoredExceptionHandler", ERROR_GEN_FAILURE);
        goto cleanup;
    }
    target = CreateThread(NULL, 0, worker_main, NULL, CREATE_SUSPENDED, &id);
    if (!target) {
        api_error("CreateThread", GetLastError());
        goto cleanup;
    }
    InterlockedExchange(&target_id, (LONG)id);

    context.ContextFlags = CONTEXT_DEBUG_REGISTERS;
    context.Dr0 = worker_address();
    context.Dr7 = 1;
    accepted = SetThreadContext(target, &context);
    if (!accepted)
        printf("  SetThreadContext winerror=%lu\n", (unsigned long)GetLastError());
    expect("SetThreadContext accepts execution breakpoint", accepted);
    if (!accepted) goto cleanup;

    context = (CONTEXT){0};
    context.ContextFlags = CONTEXT_DEBUG_REGISTERS;
    accepted = GetThreadContext(target, &context);
    if (!accepted)
        printf("  GetThreadContext winerror=%lu\n", (unsigned long)GetLastError());
    printf("  suspended DR0=%016" PRIx64 " DR7=%016" PRIx64 "\n",
           (uint64_t)context.Dr0, (uint64_t)context.Dr7);
    /* Ignore OS-normalized reserved bits; slot zero must request execution. */
    expect("suspended context retains slot-zero execution breakpoint",
           accepted && context.Dr0 == worker_address() &&
           (context.Dr7 & UINT64_C(0xf00ff)) == 1);

    if (ResumeThread(target) == (DWORD)-1) {
        api_error("ResumeThread", GetLastError());
        goto cleanup;
    }
    resumed = TRUE;
    joined = join_worker(target);
    waited = TRUE;
    if (!joined) goto cleanup;

    printf("  hits=%ld matching_contexts=%ld before_entry=%ld DR6=%016" PRIx64 "\n",
           (long)read_counter(&handler_hits), (long)read_counter(&matching_contexts),
           (long)read_counter(&hits_before_entry),
           (uint64_t)InterlockedCompareExchange64(&observed_dr6, 0, 0));
    expect("one EXCEPTION_SINGLE_STEP at entry on intended thread",
           read_counter(&handler_hits) == 1 && read_counter(&matching_contexts) == 1 &&
           read_counter(&hits_before_entry) == 1);
    if (!GetExitCodeThread(target, &exit_code)) {
        api_error("GetExitCodeThread", GetLastError());
    } else {
        printf("  worker_entries=%ld exit_code=%lu\n",
               (long)read_counter(&worker_entries), (unsigned long)exit_code);
        expect("worker executes once and returns after continuation",
               read_counter(&worker_entries) == 1 && exit_code == 0x42);
    }

cleanup:
    if (target && !resumed) {
        context = (CONTEXT){0};
        context.ContextFlags = CONTEXT_DEBUG_REGISTERS;
        if (!SetThreadContext(target, &context))
            api_error("clear context during cleanup", GetLastError());
        if (ResumeThread(target) == (DWORD)-1)
            api_error("ResumeThread cleanup", GetLastError());
        else
            resumed = TRUE;
    }
    if (target && resumed && !waited) joined = join_worker(target);
    /* Keep the handler and static state alive if a broken runtime cannot join. */
    if (handler && (!target || joined) && !RemoveVectoredExceptionHandler(handler))
        api_error("RemoveVectoredExceptionHandler", ERROR_GEN_FAILURE);
    if (target && !CloseHandle(target)) api_error("CloseHandle", GetLastError());
    printf("SUMMARY checks=%u failures=%u infrastructure_errors=%u\n",
           checks, failures, errors);
    return errors ? 2 : failures ? 1 : 0;
}

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

struct worker {
    HANDLE handle;
    DWORD id;
};

struct worker_events {
    HANDLE started;
    HANDLE complete;
};

static unsigned checks;
static unsigned failures;
static unsigned errors;
static unsigned char markers[3][4];

static DWORD WINAPI worker_main(void *argument)
{
    (void)argument;
    return 0;
}

static void api_error(const char *operation, DWORD error)
{
    ++errors;
    printf("ERROR %s winerror=%lu\n", operation, (unsigned long)error);
}

static BOOL create_worker(struct worker *worker)
{
    worker->handle = CreateThread(NULL, 0, worker_main, NULL,
                                  CREATE_SUSPENDED, &worker->id);
    if (worker->handle) return TRUE;
    api_error("CreateThread", GetLastError());
    return FALSE;
}

static void close_handle(HANDLE *handle)
{
    if (!*handle) return;
    if (!CloseHandle(*handle)) api_error("CloseHandle", GetLastError());
    *handle = NULL;
}

static BOOL finish_worker(struct worker *worker)
{
    DWORD result;
    DWORD exit_code = 0;
    BOOL finished = FALSE;

    if (!worker->handle) return TRUE;
    if (ResumeThread(worker->handle) == (DWORD)-1) {
        api_error("ResumeThread", GetLastError());
        close_handle(&worker->handle);
        return FALSE;
    }

    /* This watchdog bounds cleanup; no test depends on elapsed time. */
    result = WaitForSingleObject(worker->handle, 5000);
    if (result != WAIT_OBJECT_0) {
        api_error("WaitForSingleObject", result == WAIT_FAILED
                  ? GetLastError() : ERROR_TIMEOUT);
    } else if (!GetExitCodeThread(worker->handle, &exit_code)) {
        api_error("GetExitCodeThread", GetLastError());
    } else if (exit_code != 0) {
        api_error("worker exit code", exit_code);
    } else {
        finished = TRUE;
    }
    close_handle(&worker->handle);
    return finished;
}

static BOOL open_alias(const struct worker *worker, HANDLE *alias)
{
    *alias = OpenThread(THREAD_GET_CONTEXT | THREAD_SET_CONTEXT |
                        THREAD_QUERY_INFORMATION, FALSE, worker->id);
    if (*alias) return TRUE;
    api_error("OpenThread", GetLastError());
    return FALSE;
}

static CONTEXT debug_context(const DWORD64 values[4])
{
    CONTEXT context = {0};
    context.ContextFlags = CONTEXT_DEBUG_REGISTERS;
    context.Dr0 = values[0];
    context.Dr1 = values[1];
    context.Dr2 = values[2];
    context.Dr3 = values[3];
    /* DR7 stays zero: the probe never requests an enabled breakpoint. */
    return context;
}

static BOOL expect_set(const char *name, HANDLE target, const DWORD64 values[4])
{
    CONTEXT context = debug_context(values);
    ++checks;
    if (!SetThreadContext(target, &context)) {
        ++failures;
        printf("FAIL %s SetThreadContext winerror=%lu\n",
               name, (unsigned long)GetLastError());
        return FALSE;
    }
    printf("PASS %s SetThreadContext accepted\n", name);
    return TRUE;
}

static void expect_get(const char *name, HANDLE target, const DWORD64 expected[4])
{
    CONTEXT context = {0};
    DWORD64 actual[4];
    unsigned mismatches = 0;

    ++checks;
    context.ContextFlags = CONTEXT_DEBUG_REGISTERS;
    if (!GetThreadContext(target, &context)) {
        ++failures;
        printf("FAIL %s GetThreadContext winerror=%lu\n",
               name, (unsigned long)GetLastError());
        return;
    }
    actual[0] = context.Dr0;
    actual[1] = context.Dr1;
    actual[2] = context.Dr2;
    actual[3] = context.Dr3;
    for (unsigned i = 0; i < 4; ++i) {
        if (actual[i] == expected[i]) continue;
        ++mismatches;
        printf("  %s DR%u expected=%016" PRIx64 " actual=%016" PRIx64 "\n",
               name, i, (uint64_t)expected[i], (uint64_t)actual[i]);
    }
    /* Ignore DR6 and reserved DR7 bits that Windows may normalize. */
    if (context.Dr7 & UINT64_C(0xff)) {
        ++mismatches;
        printf("  %s unexpected DR7 enable bits=%02" PRIx64 "\n",
               name, (uint64_t)(context.Dr7 & UINT64_C(0xff)));
    }
    if (mismatches) ++failures;
    printf("%s %s GetThreadContext\n", mismatches ? "FAIL" : "PASS", name);
}

static void expect_invalid_handles(void)
{
    const DWORD64 zero[4] = {0};
    CONTEXT context = debug_context(zero);
    BOOL accepted;

    ++checks;
    accepted = SetThreadContext(NULL, &context);
    if (accepted) ++failures;
    printf("%s NULL handle SetThreadContext %s\n", accepted ? "FAIL" : "PASS",
           accepted ? "accepted" : "rejected");

    ++checks;
    context = debug_context(zero);
    accepted = GetThreadContext(NULL, &context);
    if (accepted) ++failures;
    printf("%s NULL handle GetThreadContext %s\n", accepted ? "FAIL" : "PASS",
           accepted ? "accepted" : "rejected");
}

static DWORD WINAPI waiting_worker_main(void *argument)
{
    const struct worker_events *events = argument;
    HANDLE complete = events->complete;
    DWORD result;

    if (!SetEvent(events->started)) return GetLastError();
    result = WaitForSingleObject(complete, INFINITE);
    if (result == WAIT_OBJECT_0) return 0;
    return result == WAIT_FAILED ? GetLastError() : ERROR_GEN_FAILURE;
}

static void expect_context_after_resumption(const DWORD64 values[4])
{
    /* Static storage remains valid even if a broken runtime prevents joining. */
    static struct worker_events events;
    HANDLE target = NULL;
    BOOL suspended = FALSE;
    BOOL joined = FALSE;
    DWORD result;
    DWORD exit_code = 0;

    events.started = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!events.started) {
        api_error("CreateEventW started", GetLastError());
        goto cleanup;
    }
    events.complete = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!events.complete) {
        api_error("CreateEventW complete", GetLastError());
        goto cleanup;
    }
    target = CreateThread(NULL, 0, waiting_worker_main, &events,
                          CREATE_SUSPENDED, NULL);
    if (!target) {
        api_error("CreateThread resumption target", GetLastError());
        goto cleanup;
    }
    suspended = TRUE;
    if (!expect_set("resumption target", target, values)) goto cleanup;
    expect_get("before resumption", target, values);

    if (ResumeThread(target) == (DWORD)-1) {
        api_error("ResumeThread resumption target", GetLastError());
        goto cleanup;
    }
    suspended = FALSE;
    result = WaitForSingleObject(events.started, 5000);
    if (result != WAIT_OBJECT_0) {
        api_error("worker started handshake", result == WAIT_FAILED
                  ? GetLastError() : ERROR_TIMEOUT);
        goto cleanup;
    }
    if (SuspendThread(target) == (DWORD)-1) {
        api_error("SuspendThread resumption target", GetLastError());
        goto cleanup;
    }
    suspended = TRUE;
    expect_get("values survive resumption and suspension", target, values);

cleanup:
    if (target) {
        if (!SetEvent(events.complete)) api_error("SetEvent complete", GetLastError());
        if (suspended && ResumeThread(target) == (DWORD)-1)
            api_error("ResumeThread cleanup", GetLastError());
        result = WaitForSingleObject(target, 5000);
        if (result != WAIT_OBJECT_0) {
            api_error("join resumption target", result == WAIT_FAILED
                      ? GetLastError() : ERROR_TIMEOUT);
        } else {
            joined = TRUE;
            if (!GetExitCodeThread(target, &exit_code))
                api_error("GetExitCodeThread resumption target", GetLastError());
            else if (exit_code != 0)
                api_error("resumption worker exit code", exit_code);
        }
    }
    /* A pending wait must not lose its event; process exit releases failure leftovers. */
    if (!target || joined) {
        close_handle(&events.complete);
        close_handle(&events.started);
    }
    close_handle(&target);
}

int main(void)
{
    struct worker first = {0};
    struct worker second = {0};
    struct worker replacement = {0};
    HANDLE opened = NULL;
    HANDLE duplicated = NULL;
    DWORD64 values[3][4];
    const DWORD64 zero[4] = {0};
    BOOL first_set;
    BOOL second_set;

    puts("context-probe x64: suspended targets, DR7=0, no enabled breakpoints");
    /* Marker storage is process-owned and lives until every worker exits. */
    for (unsigned row = 0; row < 3; ++row)
        for (unsigned column = 0; column < 4; ++column)
            values[row][column] = (DWORD64)(uintptr_t)&markers[row][column];

    expect_invalid_handles();
    if (!create_worker(&first) || !create_worker(&second)) goto cleanup;
    if (!open_alias(&first, &opened)) goto cleanup;
    if (!DuplicateHandle(GetCurrentProcess(), first.handle, GetCurrentProcess(),
                         &duplicated, 0, FALSE, DUPLICATE_SAME_ACCESS)) {
        api_error("DuplicateHandle", GetLastError());
        goto cleanup;
    }

    first_set = expect_set("first target", first.handle, values[0]);
    if (first_set) {
        expect_get("first direct roundtrip", first.handle, values[0]);
        expect_get("first OpenThread alias", opened, values[0]);
        expect_get("first DuplicateHandle alias", duplicated, values[0]);
    }

    second_set = expect_set("second target", second.handle, values[1]);
    if (second_set) expect_get("second roundtrip", second.handle, values[1]);
    if (first_set) expect_get("first isolated from second", opened, values[0]);

    first_set = expect_set("write through first alias", opened, values[2]);
    if (first_set) {
        expect_get("original sees alias write", first.handle, values[2]);
        expect_get("duplicate sees alias write", duplicated, values[2]);
    }
    if (second_set) expect_get("second isolated from alias write", second.handle, values[1]);

    close_handle(&opened);
    if (!open_alias(&first, &opened)) goto cleanup;
    if (first_set) expect_get("reopened alias retains context", opened, values[2]);
    if (expect_set("clear through alias", opened, zero))
        expect_get("cleared context replaces old values", duplicated, zero);

    expect_set("first values before retirement", first.handle, values[0]);
    close_handle(&opened);
    close_handle(&duplicated);
    if (!finish_worker(&first)) goto cleanup;
    if (!create_worker(&replacement)) goto cleanup;

    /* The untouched creator has not set its own context; fresh workers start clear. */
    expect_get("replacement starts without retired target values", replacement.handle, zero);
    if (expect_set("replacement target", replacement.handle, values[2]))
        expect_get("replacement roundtrip", replacement.handle, values[2]);
    if (second_set)
        expect_get("second survives first target lifetime", second.handle, values[1]);

cleanup:
    close_handle(&opened);
    close_handle(&duplicated);
    finish_worker(&replacement);
    finish_worker(&second);
    finish_worker(&first);
    if (!errors) expect_context_after_resumption(values[0]);
    printf("SUMMARY checks=%u failures=%u infrastructure_errors=%u\n",
           checks, failures, errors);
    return errors ? 2 : failures ? 1 : 0;
}

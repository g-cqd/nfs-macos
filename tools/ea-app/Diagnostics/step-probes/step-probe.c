/*
 * Standalone Windows x64 TF diagnostic, using only this executable's code.
 * The three-step sequence follows Wine's dlls/ntdll/tests/exception.c.
 * Wine test suite copyright 2005 Alexandre Julliard.
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>

#define TF_MASK UINT32_C(0x100)
#define EXPECTED_RETURN UINT32_C(0x42)
#define MAX_EVENTS 4u

extern DWORD ordinary_fixture(void);
extern DWORD step_fixture(void);
extern uint64_t read_flags(void);
extern const unsigned char step_after_xor;
extern const unsigned char step_after_push;
extern const unsigned char step_after_pop;
extern const unsigned char step_fixture_end;

struct event {
    DWORD code;
    DWORD flags;
    uintptr_t address;
    uintptr_t instruction;
};

/* The callback accepts only synchronous exceptions on the invoking thread. */
static DWORD test_thread;
static volatile BOOL active;
static volatile unsigned event_count;
static volatile unsigned overflow_count;
static volatile struct event events[MAX_EVENTS];
static unsigned checks;
static unsigned failures;

static LONG CALLBACK exception_handler(EXCEPTION_POINTERS *exception)
{
    EXCEPTION_RECORD *record = exception->ExceptionRecord;
    CONTEXT *context = exception->ContextRecord;
    uintptr_t begin = (uintptr_t)&step_fixture;
    uintptr_t end = (uintptr_t)&step_fixture_end;
    uintptr_t instruction = (uintptr_t)context->Rip;
    unsigned index;

    if (GetCurrentThreadId() != test_thread || !active ||
        record->ExceptionCode != EXCEPTION_SINGLE_STEP ||
        instruction < begin || instruction >= end)
        return EXCEPTION_CONTINUE_SEARCH;

    index = event_count;
    if (index >= MAX_EVENTS) {
        ++overflow_count;
        context->EFlags &= ~TF_MASK;
        return EXCEPTION_CONTINUE_SEARCH;
    }

    events[index].code = record->ExceptionCode;
    events[index].flags = context->EFlags;
    events[index].address = (uintptr_t)record->ExceptionAddress;
    events[index].instruction = instruction;
    event_count = index + 1;

    /* Re-arm only the first two traps; the fixture clears TF with popfq. */
    context->EFlags &= ~TF_MASK;
    if (event_count < 3) context->EFlags |= TF_MASK;
    return EXCEPTION_CONTINUE_EXECUTION;
}

static void expect(const char *name, BOOL condition)
{
    ++checks;
    if (!condition) ++failures;
    printf("%s %s\n", condition ? "PASS" : "FAIL", name);
}

int main(void)
{
    const uintptr_t expected_instructions[3] = {
        (uintptr_t)&step_after_xor,
        (uintptr_t)&step_after_push,
        (uintptr_t)&step_after_pop
    };
    PVOID handler;
    DWORD result;
    BOOL events_match;
    BOOL delivered_tf_clear;

    puts("step-probe x64: own code, TF only, no debug-register writes");
    test_thread = GetCurrentThreadId();
    if (read_flags() & TF_MASK) {
        puts("ERROR initial TF is set; run without a debugger");
        return 2;
    }
    handler = AddVectoredExceptionHandler(1, exception_handler);
    if (!handler) {
        printf("ERROR AddVectoredExceptionHandler winerror=%lu\n",
               (unsigned long)GetLastError());
        return 2;
    }

    result = ordinary_fixture();
    expect("ordinary fixture returns 0x42", result == EXPECTED_RETURN);
    expect("ordinary fixture returns with TF clear", !(read_flags() & TF_MASK));

    active = TRUE;
    result = step_fixture();
    active = FALSE;
    expect("stepped fixture returns 0x42", result == EXPECTED_RETURN);
    expect("stepped fixture returns with TF clear", !(read_flags() & TF_MASK));
    expect("exactly three single-step exceptions", event_count == 3 && !overflow_count);

    events_match = event_count == 3;
    delivered_tf_clear = event_count == 3;
    for (unsigned i = 0; i < event_count && i < MAX_EVENTS; ++i) {
        printf("EVENT index=%u code=%08lx offset=%" PRIxPTR
               " address_offset=%" PRIxPTR " flags=%08lx\n",
               i, (unsigned long)events[i].code,
               events[i].instruction - (uintptr_t)&step_fixture,
               events[i].address - (uintptr_t)&step_fixture,
               (unsigned long)events[i].flags);
        if (i >= 3 || events[i].instruction != expected_instructions[i] ||
            events[i].address != expected_instructions[i])
            events_match = FALSE;
        if (events[i].flags & TF_MASK) delivered_tf_clear = FALSE;
    }
    expect("exceptions identify the three instruction boundaries", events_match);
    expect("delivered exception contexts have TF clear", delivered_tf_clear);

    if (!RemoveVectoredExceptionHandler(handler)) {
        printf("ERROR RemoveVectoredExceptionHandler winerror=%lu\n",
               (unsigned long)GetLastError());
        return 2;
    }
    printf("SUMMARY checks=%u failures=%u exceptions=%u overflow=%u\n",
           checks, failures, event_count, overflow_count);
    return failures ? 1 : 0;
}

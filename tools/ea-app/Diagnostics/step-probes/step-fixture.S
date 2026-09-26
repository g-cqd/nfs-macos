/*
 * The TF sequence follows Wine's dlls/ntdll/tests/exception.c single_stepcode.
 * Wine test suite copyright 2005 Alexandre Julliard.
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */

.text
.p2align 4
.globl ordinary_fixture
ordinary_fixture:
    pushfq
    popq %rax
    pushq %rax
    popfq
    movl $0x42, %eax
    ret

.p2align 4
.globl step_fixture
.globl step_after_xor
.globl step_after_push
.globl step_after_pop
.globl step_fixture_end
step_fixture:
    pushfq
    popq %rax
    orl $0x100, %eax
    pushq %rax
    popfq
    xorl $0x100, %eax
step_after_xor:
    pushq %rax
step_after_push:
    popfq
step_after_pop:
    movl $0x42, %eax
    ret
step_fixture_end:

.p2align 4
.globl read_flags
read_flags:
    pushfq
    popq %rax
    ret

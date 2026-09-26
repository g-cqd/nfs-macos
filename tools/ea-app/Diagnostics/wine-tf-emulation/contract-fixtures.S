/* Owned x64 fixtures. No generated or modified executable pages are used. */
.text
.p2align 4
.globl plain_fixture
.globl plain_end
plain_fixture:
    lock incl entered(%rip)
    movl $66, %eax
    ret
plain_end:

.p2align 4
.globl busy_fixture
.globl busy_loop
.globl busy_end
busy_fixture:
    movl $0x4000000, %r8d
busy_loop:
    cmpl $0, release_gate(%rip)
    jne 1f
    pause
    decl %r8d
    jnz busy_loop
    movl $77, %eax
    ret
1:
    jmp plain_fixture
busy_end:

.p2align 4
.globl rf_fixture
.globl rf_setup
.globl rf_entry
.globl rf_end
rf_fixture:
rf_setup:
    int3
rf_entry:
    lock incl entered(%rip)
    cmpl $1, entered(%rip)
    je rf_entry
    movl $66, %eax
    ret
rf_end:

.p2align 4
.globl guest_fixture
.globl guest_setup
.globl guest_entry
.globl guest_second
.globl guest_third
.globl guest_end
guest_fixture:
guest_setup:
    int3
guest_entry:
    nop
guest_second:
    nop
guest_third:
    nop
    lock incl entered(%rip)
    movl $66, %eax
    ret
guest_end:

.p2align 4
.globl flags_fixture
.globl flags_setup
.globl flags_entry
.globl flags_target
.globl flags_end
flags_fixture:
flags_setup:
    int3
flags_entry:
    pushfq
    popq %rax
    movq %rax, observed_flags(%rip)
    pushfq
    andq $~0x100, (%rsp)
    popfq
flags_target:
    lock incl entered(%rip)
    movl $66, %eax
    ret
flags_end:

.p2align 4
.globl flags_set_fixture
.globl flags_set_setup
.globl flags_set_entry
.globl flags_set_target
.globl flags_set_end
flags_set_fixture:
flags_set_setup:
    int3
flags_set_entry:
    pushfq
    popq %rax
    movq %rax, observed_flags(%rip)
    orl $0x100, %eax
    pushq %rax
    popfq
    nop
flags_set_target:
    lock incl entered(%rip)
    movl $66, %eax
    ret
flags_set_end:

.text
.p2align 4
.globl supplement_fixture, supplement_setup, supplement_entry, supplement_target
supplement_fixture:
supplement_setup:
    int3
supplement_entry:
    nop
supplement_target:
    movl $66, %eax
    ret

.p2align 4
.globl mask_entry, mask_target
mask_entry:
    pushq %rax
    popfq
    pushfq
    popq %rax
    movq %rax, observed_mask(%rip)
    cld
mask_target:
    movl $66, %eax
    ret

.p2align 4
.globl mov_ss_entry, flag16_entry, push_fault_entry, pop_fault_entry
mov_ss_entry:
    movw %ax, %ss
    jmp supplement_target
flag16_entry:
    .byte 0x66, 0x9c
    addq $2, %rsp
    jmp supplement_target
push_fault_entry:
    pushfq
    jmp supplement_target
pop_fault_entry:
    popfq
    jmp supplement_target

.p2align 4
.globl budget_entry, elapsed_entry
budget_entry:
    movl $300000, %ecx
1:
    nop
    decl %ecx
    jnz 1b
    jmp supplement_target
elapsed_entry:
    subq $40, %rsp
    movl $6000, %ecx
    call *__imp_Sleep(%rip)
    addq $40, %rsp
    jmp supplement_target

.p2align 4
.globl visible_entry, visible_after_push, visible_target
visible_entry:
    pushfq
visible_after_push:
    popq %rax
    movq %rax, observed_mask(%rip)
visible_target:
    movl $66, %eax
    ret

.p2align 4
.globl icebp_entry
icebp_entry:
    .byte 0xf1
    nop
    jmp supplement_target

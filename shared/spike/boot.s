.section .text
.globl _start
_start:
    li sp, 0x80200000
    call main
._end:
    j ._end
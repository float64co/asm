; hello.asm - Hello World for fasm (Linux x86-64)
format ELF64 executable 3
entry start

segment readable executable

start:
    mov     rax, 1              ; sys_write
    mov     rdi, 1              ; fd = stdout
    lea     rsi, [msg]          ; buffer
    mov     rdx, msg_len        ; length
    syscall

    mov     rax, 60             ; sys_exit
    xor     rdi, rdi            ; status = 0
    syscall

segment readable writeable

msg     db 'Hello, World!', 10
msg_len = $ - msg

; mandel.asm - interactive Mandelbrot explorer for the terminal
; fasm, Linux x86-64, no libc.
;
; Uses half-block characters (upper half block, fg = top pixel, bg = bottom
; pixel) with 256-colour ANSI, so every text cell shows two square-ish pixels.
; Maths is scalar SSE2 double precision.
;
; Keys: w a s d / arrows  pan        + / -  zoom in / out (re-centres on the
;                                          set's boundary each step)
;       i / k             iterations r      reset view
;       q / Ctrl-C        quit

format ELF64 executable 3
entry start

SYS_READ    = 0
SYS_WRITE   = 1
SYS_IOCTL   = 16
SYS_EXIT    = 60
TCGETS      = 0x5401
TCSETS      = 0x5402
TIOCGWINSZ  = 0x5413

MAXCOLS     = 400
MAXROWS     = 200
ZMAX        = 85

macro puts s, n {
    lea     rsi, [s]
    mov     ecx, n
    call    put_str
}

; 256-colour cube index from r,g,b in 0..5
macro rgb r, g, b {
    db 16 + 36*r + 6*g + b
}

segment readable executable

start:
    ; ---- raw mode -------------------------------------------------------
    mov     eax, SYS_IOCTL
    xor     edi, edi
    mov     esi, TCGETS
    lea     rdx, [term_orig]
    syscall

    lea     rsi, [term_orig]
    lea     rdi, [term_raw]
    mov     ecx, 64
    rep     movsb
    and     dword [term_raw+12], 0xFFFFFFF4     ; clear ISIG|ICANON|ECHO
    mov     byte [term_raw+22], 0               ; VTIME
    mov     byte [term_raw+23], 1               ; VMIN
    mov     eax, SYS_IOCTL
    xor     edi, edi
    mov     esi, TCSETS
    lea     rdx, [term_raw]
    syscall

    lea     r15, [outbuf]
    puts    s_enter, s_enter_n
    call    flush

    call    reset_view

; ---------------------------------------------------------------------------
main_loop:
    call    getsize
    call    render
    call    flush

    mov     eax, SYS_READ
    xor     edi, edi
    lea     rsi, [keybuf]
    mov     edx, 8
    syscall
    test    rax, rax
    jle     quit

    movzx   edx, byte [keybuf]
    cmp     eax, 3
    jne     .single
    cmp     dl, 27
    jne     .single
    cmp     byte [keybuf+1], '['
    jne     .single
    movzx   edx, byte [keybuf+2]
    cmp     dl, 'A'
    mov     al, 'w'
    je      .have
    cmp     dl, 'B'
    mov     al, 's'
    je      .have
    cmp     dl, 'C'
    mov     al, 'd'
    je      .have
    cmp     dl, 'D'
    mov     al, 'a'
    je      .have
    jmp     main_loop
.have:
    movzx   edx, al
.single:
    cmp     dl, 3
    je      quit
    or      dl, 0x20                    ; fold upper case
    cmp     dl, 'q'
    je      quit
    cmp     dl, 'r'
    jne     @f
    call    reset_view
    jmp     main_loop
@@:
    cmp     dl, 'w'
    je      key_up
    cmp     dl, 's'
    je      key_down
    cmp     dl, 'a'
    je      key_left
    cmp     dl, 'd'
    je      key_right
    cmp     dl, '+'
    je      key_zin
    cmp     dl, '='
    je      key_zin
    cmp     dl, '-'
    je      key_zout
    cmp     dl, 'i'
    je      key_iup
    cmp     dl, 'k'
    je      key_idown
    jmp     main_loop

key_up:
    movsd   xmm1, [step]
    mulsd   xmm1, [c_pan]
    movsd   xmm0, [ceny]
    subsd   xmm0, xmm1
    movsd   [ceny], xmm0
    jmp     main_loop
key_down:
    movsd   xmm1, [step]
    mulsd   xmm1, [c_pan]
    movsd   xmm0, [ceny]
    addsd   xmm0, xmm1
    movsd   [ceny], xmm0
    jmp     main_loop
key_left:
    movsd   xmm1, [step]
    mulsd   xmm1, [c_pan]
    movsd   xmm0, [cenx]
    subsd   xmm0, xmm1
    movsd   [cenx], xmm0
    jmp     main_loop
key_right:
    movsd   xmm1, [step]
    mulsd   xmm1, [c_pan]
    movsd   xmm0, [cenx]
    addsd   xmm0, xmm1
    movsd   [cenx], xmm0
    jmp     main_loop
key_zin:
    cmp     dword [zlev], ZMAX
    jae     main_loop
    call    recentre
    inc     dword [zlev]
    movsd   xmm0, [step]
    mulsd   xmm0, [c_zoom]
    movsd   [step], xmm0
    jmp     main_loop
key_zout:
    cmp     dword [zlev], 0
    je      main_loop
    call    recentre
    dec     dword [zlev]
    movsd   xmm0, [step]
    divsd   xmm0, [c_zoom]
    movsd   [step], xmm0
    jmp     main_loop
key_iup:
    cmp     dword [iterbase], 4000
    jae     main_loop
    add     dword [iterbase], 32
    jmp     main_loop
key_idown:
    cmp     dword [iterbase], 32
    jbe     main_loop
    sub     dword [iterbase], 32
    jmp     main_loop

quit:
    mov     eax, SYS_IOCTL
    xor     edi, edi
    mov     esi, TCSETS
    lea     rdx, [term_orig]
    syscall
    lea     r15, [outbuf]
    puts    s_leave, s_leave_n
    call    flush
    mov     eax, SYS_EXIT
    xor     edi, edi
    syscall

; ---------------------------------------------------------------------------
; recentre: move the view centre onto the "edge" of the fractal.
; Uses the per-pixel iteration counts saved by the last render.  Each pixel is
; scored by how sharply the counts change around it (interior/exterior jumps,
; spirals, bands).  Among pixels scoring >= 3/4 of the best, the one nearest
; the screen centre becomes the new centre, so the view glides along the
; boundary instead of leaping around.  Does nothing if the view is flat.
; clobbers rax-rdx, rsi, rdi, rbp, r8-r15, xmm0-1
CAP = 32

recentre:
    mov     ebp, [cols]
    shl     ebp, 2                      ; row stride in bytes
    mov     r15, rbp
    neg     r15                         ; -stride
    mov     r12d, [cols]
    shr     r12d, 1                     ; centre px
    mov     r13d, [trows]               ; centre py
    mov     r8d, -1                     ; pass 1: nothing qualifies, find max
    call    scan
    test    r9d, r9d
    jz      .none
    lea     eax, [r9*3]
    shr     eax, 2
    mov     r8d, eax                    ; pass 2: threshold = 3/4 max
    call    scan
    cvtsi2sd xmm0, r10d
    mulsd   xmm0, [step]
    addsd   xmm0, [x0]
    movsd   [cenx], xmm0
    cvtsi2sd xmm1, r11d
    mulsd   xmm1, [step]
    addsd   xmm1, [y0]
    movsd   [ceny], xmm1
.none:
    ret

; scan: r8d = threshold.  Returns r9d = max score, r10d/r11d = px/py of the
; qualifying pixel nearest the centre (r12d, r13d).
scan:
    mov     dword [bestd], 0x7FFFFFFF
    xor     r9d, r9d
    lea     rsi, [iterbuf]
    add     rsi, rbp
    add     rsi, 4                      ; pixel (1,1)
    mov     ecx, 1                      ; py
.y: lea     eax, [ecx+1]
    mov     edx, [trows]
    add     edx, edx
    cmp     eax, edx
    jae     .ret
    mov     edx, 1                      ; px
.x: lea     eax, [edx+1]
    cmp     eax, [cols]
    jae     .ny
    call    rugged
    cmp     eax, r9d
    jbe     @f
    mov     r9d, eax
@@: cmp     eax, r8d
    jb      .nx
    mov     eax, edx
    sub     eax, r12d
    imul    eax, eax
    mov     edi, ecx
    sub     edi, r13d
    imul    edi, edi
    add     eax, edi
    cmp     eax, [bestd]
    jae     .nx
    mov     [bestd], eax
    mov     r10d, edx
    mov     r11d, ecx
.nx:
    add     rsi, 4
    inc     edx
    jmp     .x
.ny:
    add     rsi, 8
    inc     ecx
    jmp     .y
.ret:
    ret

; rugged: rsi -> iterbuf entry (not on the edge), rbp = stride, r15 = -stride
; -> eax = sum over 4 neighbours of min(|v - neighbour|, CAP).
; clobbers ebx, edi, r14d
macro nbr addr {
    mov     edi, addr
    sub     edi, ebx
    mov     r14d, edi
    neg     edi
    cmovs   edi, r14d                   ; |v - n|
    cmp     edi, CAP
    jbe     @f
    mov     edi, CAP
@@: add     eax, edi
}
rugged:
    mov     ebx, [rsi]
    xor     eax, eax
    nbr     [rsi-4]
    nbr     [rsi+4]
    nbr     [rsi+rbp]
    nbr     [rsi+r15]
    ret

; ---------------------------------------------------------------------------
; reset_view: centre on the whole set, fit to the current terminal size
reset_view:
    call    getsize
    movsd   xmm0, [c_3_5]
    cvtsi2sd xmm2, dword [cols]
    divsd   xmm0, xmm2                  ; 3.5 / cols
    mov     eax, [trows]
    add     eax, eax
    cvtsi2sd xmm2, eax
    movsd   xmm1, [c_2_6]
    divsd   xmm1, xmm2                  ; 2.6 / pixel rows
    maxsd   xmm0, xmm1
    movsd   [step], xmm0
    movsd   xmm0, [c_m0_5]
    movsd   [cenx], xmm0
    xorpd   xmm0, xmm0
    movsd   [ceny], xmm0
    mov     dword [zlev], 0
    mov     dword [iterbase], 96
    ret

; getsize: fills [cols] (<= MAXCOLS) and [trows] = text rows - 1 (status line)
getsize:
    mov     eax, SYS_IOCTL
    mov     edi, 1
    mov     esi, TIOCGWINSZ
    lea     rdx, [winsz]
    syscall
    movzx   eax, word [winsz]           ; rows
    movzx   ecx, word [winsz+2]         ; cols
    test    eax, eax
    jnz     @f
    mov     eax, 24
@@: test    ecx, ecx
    jnz     @f
    mov     ecx, 80
@@: cmp     ecx, MAXCOLS
    jbe     @f
    mov     ecx, MAXCOLS
@@: cmp     eax, MAXROWS
    jbe     @f
    mov     eax, MAXROWS
@@: mov     [cols], ecx
    dec     eax
    jnz     @f
    mov     eax, 1
@@: mov     [trows], eax
    ret

; flush: write outbuf .. r15 to stdout
flush:
    lea     rsi, [outbuf]
    mov     rdx, r15
    sub     rdx, rsi
.w: test    rdx, rdx
    jle     .d
    mov     eax, SYS_WRITE
    mov     edi, 1
    syscall
    test    rax, rax
    jle     .d
    add     rsi, rax
    sub     rdx, rax
    jmp     .w
.d: lea     r15, [outbuf]
    ret

; ---------------------------------------------------------------------------
; output helpers; r15 is the output pointer
; put_str: append rcx bytes from rsi.  clobbers rsi, rdi, rcx
put_str:
    mov     rdi, r15
    rep     movsb
    mov     r15, rdi
    ret

; put_num: append eax in decimal.  clobbers rax, rcx, rdx, r8
put_num:
    mov     r8d, 10
    xor     ecx, ecx
.d: xor     edx, edx
    div     r8d
    push    rdx
    inc     ecx
    test    eax, eax
    jnz     .d
.w: pop     rax
    add     al, '0'
    mov     [r15], al
    inc     r15
    dec     ecx
    jnz     .w
    ret

; put_fixed: append xmm0 as [-]I.FFFFFFFFFFFF (12 decimals).
; clobbers rax, rcx, rdx, r8, r9, xmm0
put_fixed:
    movq    rax, xmm0
    bt      rax, 63
    jnc     @f
    btr     rax, 63
    movq    xmm0, rax
    mov     byte [r15], '-'
    inc     r15
@@: mulsd   xmm0, [c_1e12]
    cvtsd2si rax, xmm0
    xor     edx, edx
    mov     r8, 1000000000000
    div     r8
    mov     r9, rdx                     ; fraction
    call    put_num                     ; integer part (eax)
    mov     byte [r15], '.'
    inc     r15
    mov     rax, r9
    mov     r8d, 10
    mov     ecx, 12
.p: xor     edx, edx
    div     r8
    push    rdx
    dec     ecx
    jnz     .p
    mov     ecx, 12
.w: pop     rax
    add     al, '0'
    mov     [r15], al
    inc     r15
    dec     ecx
    jnz     .w
    ret

; ---------------------------------------------------------------------------
; mandel: xmm0 = cr, xmm1 = ci  ->  eax = iterations (== [maxit] if inside)
; clobbers ecx, edx, xmm2-xmm7
mandel:
    xorpd   xmm2, xmm2                  ; zr
    xorpd   xmm3, xmm3                  ; zi
    xorpd   xmm4, xmm4                  ; zr^2
    xorpd   xmm5, xmm5                  ; zi^2
    xor     ecx, ecx
    mov     edx, [maxit]
.l: movapd  xmm6, xmm2
    mulsd   xmm6, xmm3
    addsd   xmm6, xmm6
    addsd   xmm6, xmm1                  ; zi' = 2 zr zi + ci
    movapd  xmm3, xmm6
    movapd  xmm2, xmm4
    subsd   xmm2, xmm5
    addsd   xmm2, xmm0                  ; zr' = zr^2 - zi^2 + cr
    movapd  xmm4, xmm2
    mulsd   xmm4, xmm4
    movapd  xmm5, xmm3
    mulsd   xmm5, xmm5
    movapd  xmm7, xmm4
    addsd   xmm7, xmm5
    ucomisd xmm7, [c_4]
    ja      .esc
    inc     ecx
    cmp     ecx, edx
    jb      .l
.esc:
    mov     eax, ecx
    ret

; colour: eax = iterations -> eax = 256-colour index.  clobbers ecx, edx
colour:
    cmp     eax, [maxit]
    jae     .in
    xor     edx, edx
    mov     ecx, PALN
    div     ecx
    movzx   eax, byte [pal+rdx]
    ret
.in:
    mov     eax, 16
    ret

; ---------------------------------------------------------------------------
; render: draw a full frame into outbuf (r15 left at end)
render:
    lea     r15, [outbuf]
    puts    s_home, s_home_n

    mov     eax, [zlev]
    imul    eax, eax, 10
    add     eax, [iterbase]
    mov     [maxit], eax

    ; x0 = cx - (cols/2)*step     y0 = cy - trows*step
    cvtsi2sd xmm0, dword [cols]
    mulsd   xmm0, [c_half]
    mulsd   xmm0, [step]
    movsd   xmm1, [cenx]
    subsd   xmm1, xmm0
    movsd   [x0], xmm1
    cvtsi2sd xmm0, dword [trows]
    mulsd   xmm0, [step]
    movsd   xmm1, [ceny]
    subsd   xmm1, xmm0
    movsd   [y0], xmm1

    mov     dword [prevt], -1
    mov     dword [prevb], -1
    xor     r12d, r12d                  ; text row
.row:
    cmp     r12d, [trows]
    jae     .status
    lea     eax, [r12*2]
    cvtsi2sd xmm0, eax
    mulsd   xmm0, [step]
    addsd   xmm0, [y0]
    movsd   [citop], xmm0
    addsd   xmm0, [step]
    movsd   [cibot], xmm0
    xor     r13d, r13d                  ; column
.col:
    cmp     r13d, [cols]
    jae     .endrow
    cvtsi2sd xmm0, r13d
    mulsd   xmm0, [step]
    addsd   xmm0, [x0]
    movsd   [curcr], xmm0
    movsd   xmm1, [citop]
    call    mandel
    mov     edi, eax
    mov     eax, [cols]
    lea     esi, [r12*2]
    imul    esi, eax
    add     esi, r13d
    mov     [iterbuf+rsi*4], edi        ; remember count for recentre
    mov     eax, edi
    call    colour
    mov     r14d, eax                   ; top colour
    movsd   xmm0, [curcr]
    movsd   xmm1, [cibot]
    call    mandel
    mov     edi, eax
    mov     eax, [cols]
    lea     esi, [r12*2+1]
    imul    esi, eax
    add     esi, r13d
    mov     [iterbuf+rsi*4], edi
    mov     eax, edi
    call    colour
    mov     ebx, eax                    ; bottom colour

    cmp     r14d, [prevt]
    jne     .emit
    cmp     ebx, [prevb]
    je      .block
.emit:
    mov     [prevt], r14d
    mov     [prevb], ebx
    puts    s_fg, s_fg_n
    mov     eax, r14d
    call    put_num
    puts    s_bg, s_bg_n
    mov     eax, ebx
    call    put_num
    puts    s_m, 1
.block:
    puts    s_block, 3
    inc     r13d
    jmp     .col
.endrow:
    puts    s_eol, s_eol_n
    mov     dword [prevt], -1
    mov     dword [prevb], -1
    inc     r12d
    jmp     .row

.status:
    puts    s_st1, s_st1_n
    movsd   xmm0, [cenx]
    call    put_fixed
    puts    s_st2, s_st2_n
    movsd   xmm0, [ceny]
    call    put_fixed
    puts    s_st3, s_st3_n
    mov     eax, [zlev]
    call    put_num
    puts    s_st4, s_st4_n
    mov     eax, [maxit]
    call    put_num
    puts    s_st5, s_st5_n
    ret

; ---------------------------------------------------------------------------
segment readable writeable

s_enter:  db 27,'[?1049h',27,'[?25l',27,'[?7l',27,'[2J'
s_enter_n = $ - s_enter
s_leave:  db 27,'[0m',27,'[?7h',27,'[?25h',27,'[?1049l'
s_leave_n = $ - s_leave
s_home:   db 27,'[H'
s_home_n = $ - s_home
s_fg:     db 27,'[38;5;'
s_fg_n = $ - s_fg
s_bg:     db ';48;5;'
s_bg_n = $ - s_bg
s_m:      db 'm'
s_block:  db 0xE2,0x96,0x80                 ; U+2580 upper half block
s_eol:    db 27,'[0m',13,10
s_eol_n = $ - s_eol
s_st1:    db 27,'[0m',27,'[7m',' re '
s_st1_n = $ - s_st1
s_st2:    db '  im '
s_st2_n = $ - s_st2
s_st3:    db '  zoom '
s_st3_n = $ - s_st3
s_st4:    db '  iter '
s_st4_n = $ - s_st4
s_st5:    db '  | wasd move  +/- zoom  i/k iter  r reset  q quit ',27,'[K',27,'[0m'
s_st5_n = $ - s_st5

; blue -> cyan -> green -> yellow -> red -> magenta -> blue
pal:
    rgb 0,0,1
    rgb 0,0,2
    rgb 0,0,3
    rgb 0,0,4
    rgb 0,0,5
    rgb 0,1,5
    rgb 0,2,5
    rgb 0,3,5
    rgb 0,4,5
    rgb 0,5,5
    rgb 0,5,4
    rgb 0,5,3
    rgb 0,5,2
    rgb 0,5,1
    rgb 0,5,0
    rgb 1,5,0
    rgb 2,5,0
    rgb 3,5,0
    rgb 4,5,0
    rgb 5,5,0
    rgb 5,4,0
    rgb 5,3,0
    rgb 5,2,0
    rgb 5,1,0
    rgb 5,0,0
    rgb 5,0,1
    rgb 5,0,2
    rgb 5,0,3
    rgb 5,0,4
    rgb 5,0,5
    rgb 4,0,5
    rgb 3,0,5
    rgb 2,0,5
    rgb 1,0,5
PALN = $ - pal

align 8
c_4:      dq 4.0
c_half:   dq 0.5
c_pan:    dq 6.0
c_zoom:   dq 0.75
c_3_5:    dq 3.5
c_2_6:    dq 2.6
c_m0_5:   dq -0.5
c_1e12:   dq 1.0e12

cenx:       dq -0.5
ceny:       dq 0.0
step:     dq 0.04
x0:       dq 0.0
y0:       dq 0.0
citop:    dq 0.0
cibot:    dq 0.0
curcr:    dq 0.0

zlev:     dd 0
iterbase: dd 96
maxit:    dd 96
cols:     dd 80
trows:    dd 23
prevt:    dd -1
prevb:    dd -1
bestd:    dd 0

winsz:    rw 4
keybuf:   rb 16
term_orig: rb 64
term_raw:  rb 64
iterbuf:  rd MAXCOLS*MAXROWS*2
outbuf:   rb 2200000

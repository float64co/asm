; ray.asm - single-file raytracer -> PPM -> PNG
; fasm, Linux x86-64, no libc, needs SSE4.1 (dpps/roundps/blendps).
;
; Scene: a closed room with green walls, a checkered floor, four spheres
; (one a mirror) and a yawed cube.  Three point lights (dim white, purple,
; green) with inverse-square-ish falloff, shadows, Blinn-Phong highlights,
; up to 5 reflection bounces, 2x2 supersampling.  Writes out.ppm and out.png;
; the PNG encoder is built in (CRC32 + Adler-32 + stored deflate blocks).
;
; A 3-vector is one xmm register of 4 floats (x,y,z,0); scalars are broadcast
; into all four lanes so dpps/mulps work directly.
;
; Threads: clone() workers (one per CPU) pull rows from an atomic counter.
; Build with a bigger fasm heap for the 1080p buffers:  fasm -m 131072 ray.asm

format ELF64 executable 3
entry start

W           = 1920
H           = 1080
MAXDEPTH    = 5
NSPH        = 4
NPLANES     = 6
NLIGHTS     = 3
RAWLEN      = H * (W*3 + 1)             ; scanlines + filter byte
NBLK        = (RAWLEN + 65534) / 65535  ; stored deflate blocks
IDATLEN     = 2 + NBLK*5 + RAWLEN + 4   ; zlib hdr + blocks + adler

; object ids: 0..NSPH-1 spheres, NSPH cube, NSPH+1.. planes
MAXTHREADS  = 64
STACKSZ     = 65536
TLSSIZE     = 256                       ; per-thread scratch block

; per-thread scratch layout (offsets from rdi inside the render code)
T_TMPV  = 0
T_TMPI  = 16
T_SUM   = 32
T_REFL  = 48
T_LDIR  = 64
T_LDIST = 80
T_LATT  = 96
T_DTERM = 112
T_LACC  = 128
T_SACC  = 144

CLONE_FLAGS = 0x50F00                   ; VM|FS|FILES|SIGHAND|THREAD|SYSVSEM

ID_CUBE     = NSPH
ID_PLANE0   = NSPH + 1

macro splat v { dd v, v, v, v }
macro vec x, y, z { dd x, y, z, 0.0 }

; sphere (64 bytes): centre, colour, r^2 (splat), reflectivity (splat)
macro sphere cx, cy, cz, r2, cr, cg, cb, refl {
    vec cx, cy, cz
    vec cr, cg, cb
    splat r2
    splat refl
}

; plane (80 bytes): inward normal, d (n.P = d), colour A, colour B, refl
macro plane nx, ny, nz, d, ar, ag, ab, br, bg, bb, refl {
    vec nx, ny, nz
    splat d
    vec ar, ag, ab
    vec br, bg, bb
    splat refl
}

; light (32 bytes): position, colour (intensity folded in)
macro light x, y, z, r, g, b {
    vec x, y, z
    vec r, g, b
}

segment readable executable

start:
    call    mk_crctab

    ; number of usable CPUs = popcount of the affinity mask
    mov     eax, 204                    ; sched_getaffinity(0, 1024, mask)
    xor     edi, edi
    mov     esi, 1024
    lea     rdx, [cpumask]
    syscall
    xor     r12d, r12d
    mov     ecx, eax
    shr     ecx, 3
    jz      .cnt
    lea     rsi, [cpumask]
.pc:
    popcnt  rax, [rsi]
    add     r12d, eax
    add     rsi, 8
    dec     ecx
    jnz     .pc
.cnt:
    test    r12d, r12d
    jnz     @f
    mov     r12d, 1
@@: cmp     r12d, MAXTHREADS
    jbe     @f
    mov     r12d, MAXTHREADS
@@: mov     [nthreads], r12d

    ; spawn threads 1..n-1; the main thread is thread 0
    mov     ebx, 1
.sp:
    cmp     ebx, [nthreads]
    jae     .spd
    mov     eax, ebx
    inc     eax
    imul    eax, eax, STACKSZ
    lea     rsi, [stacks+rax-16]        ; child stack top
    mov     [rsi], rbx                  ; thread id, popped by the child
    mov     edi, CLONE_FLAGS
    xor     edx, edx
    xor     r10d, r10d
    xor     r8d, r8d
    mov     eax, 56                     ; clone
    syscall
    test    eax, eax
    jnz     .parent
    pop     rax                         ; child: thread id
    imul    rax, rax, TLSSIZE
    lea     rdi, [tls+rax]
    call    worker
    lock inc dword [finished]
    mov     eax, 60                     ; exit (this thread only)
    xor     edi, edi
    syscall
.parent:
    inc     ebx
    jmp     .sp
.spd:
    lea     rdi, [tls]
    call    worker
    mov     r13d, [nthreads]
    dec     r13d
.wt:
    cmp     dword [finished], r13d
    jae     .wd
    mov     eax, 24                     ; sched_yield
    syscall
    jmp     .wt
.wd:
    call    write_ppm
    call    make_png
    call    write_png
    mov     eax, 1
    mov     edi, 1
    lea     rsi, [s_done]
    mov     edx, s_done_n
    syscall
    mov     eax, 60
    xor     edi, edi
    syscall

; ---------------------------------------------------------------------------
; normalize: xmm0 = v -> xmm0 = v / |v|.  clobbers xmm1
normalize:
    movaps  xmm1, xmm0
    dpps    xmm1, xmm1, 0x7F
    sqrtps  xmm1, xmm1
    divps   xmm0, xmm1
    ret

; rot: rotate xmm0 by the 3 row vectors at rsi (rows 0 and 2 used; the
; matrix is a rotation about Y).  -> xmm0.  clobbers xmm1, xmm2
rot:
    movaps  xmm1, xmm0
    dpps    xmm1, [rsi], 0x7F           ; x' = row0 . v
    movaps  xmm2, xmm0
    dpps    xmm2, [rsi+32], 0x7F        ; z' = row2 . v
    blendps xmm1, xmm0, 0010b           ; y' = y
    blendps xmm1, xmm2, 0100b
    andps   xmm1, [c_mask3]             ; w = 0
    movaps  xmm0, xmm1
    ret

; sphere_t: xmm4 = ray origin, xmm5 = ray dir (unit), rsi -> sphere
; -> xmm0 = nearest positive t (splat), or 1e30 if missed.  clobbers xmm0-xmm3
sphere_t:
    movaps  xmm0, xmm4
    subps   xmm0, [rsi]                 ; oc = O - C
    movaps  xmm1, xmm0
    dpps    xmm1, xmm5, 0x7F            ; b  = oc . D
    dpps    xmm0, xmm0, 0x7F            ; oc . oc
    subps   xmm0, [rsi+32]              ; c  = oc.oc - r^2
    movaps  xmm2, xmm1
    mulps   xmm2, xmm2
    subps   xmm2, xmm0                  ; disc = b^2 - c
    xorps   xmm3, xmm3
    comiss  xmm2, xmm3
    jb      .miss
    sqrtps  xmm2, xmm2
    subps   xmm3, xmm1                  ; -b
    movaps  xmm0, xmm3
    subps   xmm0, xmm2                  ; t1 = -b - sqrt
    comiss  xmm0, [c_eps]
    ja      .ret
    addps   xmm3, xmm2
    movaps  xmm0, xmm3                  ; t2 = -b + sqrt
    comiss  xmm0, [c_eps]
    ja      .ret
.miss:
    movaps  xmm0, [c_big]
.ret:
    ret

; cube_t: xmm4 = origin, xmm5 = dir -> xmm0 = t (splat) or 1e30.
; The ray is moved into the cube's local frame (translate, un-yaw) and
; intersected with the slab pair on each axis.
; clobbers xmm0-xmm3, xmm6, xmm7, rsi
cube_t:
    movaps  xmm0, xmm4
    subps   xmm0, [cube_c]
    lea     rsi, [cube_rotF]
    call    rot
    movaps  xmm6, xmm0                  ; O'
    movaps  xmm0, xmm5
    call    rot
    movaps  xmm7, xmm0                  ; D'
    movaps  xmm1, [c_one]
    divps   xmm1, xmm7                  ; 1 / D'
    movaps  xmm2, [cube_h]
    movaps  xmm3, xmm2
    xorps   xmm3, [c_signmask]          ; -h
    subps   xmm3, xmm6
    mulps   xmm3, xmm1                  ; t1 = (-h - O') / D'
    subps   xmm2, xmm6
    mulps   xmm2, xmm1                  ; t2 = ( h - O') / D'
    movaps  xmm0, xmm3
    minps   xmm0, xmm2                  ; per-axis entry
    maxps   xmm3, xmm2                  ; per-axis exit
    movaps  xmm1, xmm0
    shufps  xmm1, xmm1, 0x4E
    maxps   xmm0, xmm1
    movaps  xmm1, xmm0
    shufps  xmm1, xmm1, 0xB1
    maxps   xmm0, xmm1                  ; tnear = max of entries
    movaps  xmm1, xmm3
    shufps  xmm1, xmm1, 0x4E
    minps   xmm3, xmm1
    movaps  xmm1, xmm3
    shufps  xmm1, xmm1, 0xB1
    minps   xmm3, xmm1                  ; tfar = min of exits
    comiss  xmm0, xmm3
    ja      .miss
    comiss  xmm3, [c_eps]
    jbe     .miss
    comiss  xmm0, [c_eps]
    ja      .ret
    movaps  xmm0, xmm3                  ; started inside
    ret
.miss:
    movaps  xmm0, [c_big]
.ret:
    ret

; occluded: shadow ray xmm4 = origin, xmm5 = dir, [rdi+T_LDIST] = light distance
; -> r8d = 1 if a sphere or the cube blocks it.  clobbers xmm0-3, 6, 7, rsi, ebx
occluded:
    lea     rsi, [spheres]
    xor     ebx, ebx
.l: call    sphere_t
    comiss  xmm0, [rdi+T_LDIST]
    jb      .yes
    add     rsi, 64
    inc     ebx
    cmp     ebx, NSPH
    jb      .l
    call    cube_t
    comiss  xmm0, [rdi+T_LDIST]
    jb      .yes
    xor     r8d, r8d
    ret
.yes:
    mov     r8d, 1
    ret

; ---------------------------------------------------------------------------
; trace: xmm8 = origin, xmm9 = direction (unit) -> xmm11 = colour (rgb)
; Iterative reflections: colour += weight * (1-refl) * local; weight *= refl
; keeps r10, r14, r15, rbp
trace:
    xorps   xmm11, xmm11
    movaps  xmm10, [c_one]              ; weight
    mov     r13d, MAXDEPTH
.bounce:
    movaps  xmm12, [c_big]              ; best t
    mov     r12d, -1                    ; best object id
    movaps  xmm4, xmm8
    movaps  xmm5, xmm9

    lea     rsi, [spheres]
    xor     ebx, ebx
.sl:
    call    sphere_t
    comiss  xmm0, xmm12
    jae     .sn
    movaps  xmm12, xmm0
    mov     r12d, ebx
.sn:
    add     rsi, 64
    inc     ebx
    cmp     ebx, NSPH
    jb      .sl

    call    cube_t
    comiss  xmm0, xmm12
    jae     .nocube
    movaps  xmm12, xmm0
    mov     r12d, ID_CUBE
.nocube:

    lea     rsi, [planes]
    mov     ebx, ID_PLANE0
.pl:
    movaps  xmm1, [rsi]
    dpps    xmm1, xmm9, 0x7F            ; n . D
    comiss  xmm1, [c_negeps]
    jae     .pn                         ; not facing the ray
    movaps  xmm2, [rsi+16]              ; d
    movaps  xmm3, [rsi]
    dpps    xmm3, xmm8, 0x7F            ; n . O
    subps   xmm2, xmm3
    divps   xmm2, xmm1                  ; t = (d - n.O) / (n.D)
    comiss  xmm2, [c_eps]
    jbe     .pn
    comiss  xmm2, xmm12
    jae     .pn
    movaps  xmm12, xmm2
    mov     r12d, ebx
.pn:
    add     rsi, 80
    inc     ebx
    cmp     ebx, ID_PLANE0 + NPLANES
    jb      .pl

    cmp     r12d, -1
    jne     .hit
    ret                                 ; escaped the room (shouldn't happen)

.hit:
    movaps  xmm13, xmm9
    mulps   xmm13, xmm12
    addps   xmm13, xmm8                 ; P = O + D t
    cmp     r12d, NSPH
    je      .cube
    ja      .plane

    ; ---- sphere ----
    mov     eax, r12d
    shl     eax, 6
    lea     rsi, [spheres+rax]
    movaps  xmm0, xmm13
    subps   xmm0, [rsi]
    call    normalize
    movaps  xmm14, xmm0                 ; N
    movaps  xmm15, [rsi+16]             ; surface colour
    movaps  xmm0, [rsi+48]
    movaps  [rdi+T_REFL], xmm0
    jmp     .shade

.cube:
    ; local-frame hit point; the normal is the face axis with the largest |p|
    movaps  xmm0, xmm13
    subps   xmm0, [cube_c]
    lea     rsi, [cube_rotF]
    call    rot
    movaps  xmm1, xmm0
    andps   xmm1, [c_absmask]
    movaps  xmm2, xmm1
    shufps  xmm2, xmm2, 0x4E
    maxps   xmm2, xmm1
    movaps  xmm3, xmm2
    shufps  xmm3, xmm3, 0xB1
    maxps   xmm2, xmm3                  ; max |p| (splat)
    cmpeqps xmm1, xmm2                  ; lane mask of the dominant axis
    andps   xmm0, [c_signmask]
    orps    xmm0, [c_one]               ; +-1 with the sign of p
    andps   xmm0, xmm1                  ; local normal
    lea     rsi, [cube_rotB]
    call    rot                         ; back to world space
    call    normalize
    movaps  xmm14, xmm0
    movaps  xmm15, [cube_col]
    movaps  xmm0, [cube_refl]
    movaps  [rdi+T_REFL], xmm0
    jmp     .shade

.plane:
    mov     eax, r12d
    sub     eax, ID_PLANE0
    imul    eax, eax, 80
    lea     rsi, [planes+rax]
    movaps  xmm14, [rsi]                ; N (inward)
    roundps xmm1, xmm13, 1              ; floor(P)
    cvttps2dq xmm1, xmm1
    movd    eax, xmm1
    pextrd  edx, xmm1, 2
    add     eax, edx
    movaps  xmm15, [rsi+32]
    test    al, 1
    jz      @f
    movaps  xmm15, [rsi+48]
@@: movaps  xmm0, [rsi+64]
    movaps  [rdi+T_REFL], xmm0

; ---- lighting: sum over all lights ----
.shade:
    movaps  xmm0, [c_amb]
    movaps  [rdi+T_LACC], xmm0
    xorps   xmm0, xmm0
    movaps  [rdi+T_SACC], xmm0
    lea     r9, [lights]
    mov     r11d, NLIGHTS
.light:
    movaps  xmm0, [r9]
    subps   xmm0, xmm13                 ; towards the light
    movaps  xmm1, xmm0
    dpps    xmm1, xmm1, 0x7F            ; d^2
    movaps  xmm2, xmm1
    mulps   xmm2, [c_attk]
    addps   xmm2, [c_one]
    movaps  xmm3, [c_one]
    divps   xmm3, xmm2
    movaps  [rdi+T_LATT], xmm3                ; 1 / (1 + k d^2)
    sqrtps  xmm1, xmm1
    movaps  [rdi+T_LDIST], xmm1
    divps   xmm0, xmm1
    movaps  [rdi+T_LDIR], xmm0                ; L
    movaps  xmm6, xmm14
    dpps    xmm6, xmm0, 0x7F            ; d = N . L
    xorps   xmm1, xmm1
    comiss  xmm6, xmm1
    jbe     .nextlight                  ; faces away from the light
    movaps  [rdi+T_DTERM], xmm6
    movaps  xmm4, xmm14
    mulps   xmm4, [c_eps]
    addps   xmm4, xmm13
    movaps  xmm5, xmm0
    call    occluded
    test    r8d, r8d
    jnz     .nextlight
    movaps  xmm7, [r9+16]
    mulps   xmm7, [rdi+T_LATT]                ; light colour * attenuation
    movaps  xmm0, xmm7
    mulps   xmm0, [rdi+T_DTERM]
    addps   xmm0, [rdi+T_LACC]
    movaps  [rdi+T_LACC], xmm0                ; diffuse
    movaps  xmm0, [rdi+T_LDIR]
    subps   xmm0, xmm9
    call    normalize                   ; H
    dpps    xmm0, xmm14, 0x7F
    xorps   xmm1, xmm1
    maxps   xmm0, xmm1
    mulps   xmm0, xmm0
    mulps   xmm0, xmm0
    mulps   xmm0, xmm0
    mulps   xmm0, xmm0
    mulps   xmm0, xmm0                  ; (N.H)^32
    mulps   xmm0, [c_spec]
    mulps   xmm0, xmm7
    addps   xmm0, [rdi+T_SACC]
    movaps  [rdi+T_SACC], xmm0                ; specular
.nextlight:
    add     r9, 32
    dec     r11d
    jnz     .light

    movaps  xmm1, xmm15
    mulps   xmm1, [rdi+T_LACC]
    addps   xmm1, [rdi+T_SACC]                ; local colour
    movaps  xmm2, [c_one]
    subps   xmm2, [rdi+T_REFL]
    mulps   xmm2, xmm10
    mulps   xmm1, xmm2
    addps   xmm11, xmm1

    mulps   xmm10, [rdi+T_REFL]
    comiss  xmm10, [c_minw]
    jb      .done

    ; reflect: D' = D - 2 (D.N) N,  O' = P + N eps
    movaps  xmm0, xmm9
    dpps    xmm0, xmm14, 0x7F
    addps   xmm0, xmm0
    mulps   xmm0, xmm14
    subps   xmm9, xmm0
    movaps  xmm8, xmm14
    mulps   xmm8, [c_eps]
    addps   xmm8, xmm13
    dec     r13d
    jnz     .bounce
.done:
    ret

; ---------------------------------------------------------------------------
; worker: rdi = this thread's scratch block.  Repeatedly claims the next
; unrendered row (atomic fetch-and-add) and renders it, 2x2 supersampled.
worker:
.y: mov     eax, 1
    lock xadd [next_row], eax           ; eax = row to render
    cmp     eax, H
    jae     .ret
    mov     r15d, eax                   ; y
    imul    eax, eax, W*3
    lea     rbp, [fb+rax]
    xor     r14d, r14d                  ; x
.x: cmp     r14d, W
    jae     .ny
    xorps   xmm0, xmm0
    movaps  [rdi+T_SUM], xmm0
    xor     r10d, r10d                  ; sample
.s: cmp     r10d, 4
    jae     .sd
    ; px = x + 0.25 + 0.5*(s&1) ; dir.x = (px - W/2) * scale
    cvtsi2ss xmm0, r14d
    addss   xmm0, [c_q]
    mov     eax, r10d
    and     eax, 1
    cvtsi2ss xmm1, eax
    mulss   xmm1, [c_h]
    addss   xmm0, xmm1
    subss   xmm0, [c_halfw]
    mulss   xmm0, [c_scale]
    movss   [rdi+T_TMPV], xmm0
    ; py = y + 0.25 + 0.5*(s>>1) ; dir.y = -(py - H/2) * scale + tilt
    cvtsi2ss xmm0, r15d
    addss   xmm0, [c_q]
    mov     eax, r10d
    shr     eax, 1
    cvtsi2ss xmm1, eax
    mulss   xmm1, [c_h]
    addss   xmm0, xmm1
    subss   xmm0, [c_halfh]
    mulss   xmm0, [c_nscale]
    addss   xmm0, [c_tilt]
    movss   [rdi+T_TMPV+4], xmm0
    mov     dword [rdi+T_TMPV+8], 1.0
    mov     dword [rdi+T_TMPV+12], 0
    movaps  xmm0, [rdi+T_TMPV]
    call    normalize
    movaps  xmm9, xmm0
    movaps  xmm8, [c_cam]
    call    trace
    movaps  xmm0, [rdi+T_SUM]
    addps   xmm0, xmm11
    movaps  [rdi+T_SUM], xmm0
    inc     r10d
    jmp     .s
.sd:
    movaps  xmm0, [rdi+T_SUM]
    mulps   xmm0, [c_quarter]
    xorps   xmm1, xmm1
    maxps   xmm0, xmm1
    minps   xmm0, [c_one]
    sqrtps  xmm0, xmm0                  ; gamma 2.0
    mulps   xmm0, [c_255]
    cvtps2dq xmm0, xmm0
    movaps  [rdi+T_TMPI], xmm0
    mov     eax, [rdi+T_TMPI]
    mov     [rbp], al
    mov     eax, [rdi+T_TMPI+4]
    mov     [rbp+1], al
    mov     eax, [rdi+T_TMPI+8]
    mov     [rbp+2], al
    add     rbp, 3
    inc     r14d
    jmp     .x
.ny:
    jmp     .y
.ret:
    ret

; ---------------------------------------------------------------------------
; file helpers
; file_create: rdi -> name.  [fd] = descriptor
file_create:
    mov     eax, 2                      ; open
    mov     esi, 0x241                  ; O_WRONLY|O_CREAT|O_TRUNC
    mov     edx, 0x1A4                  ; 0644
    syscall
    mov     [fd], eax
    ret

; file_write: rsi -> data, rdx = length
file_write:
.w: test    rdx, rdx
    jle     .d
    mov     eax, 1
    mov     edi, [fd]
    syscall
    test    rax, rax
    jle     .d
    add     rsi, rax
    sub     rdx, rax
    jmp     .w
.d: ret

file_close:
    mov     eax, 3
    mov     edi, [fd]
    syscall
    ret

write_ppm:
    lea     rdi, [n_ppm]
    call    file_create
    lea     rsi, [ppm_hdr]
    mov     edx, ppm_hdr_n
    call    file_write
    lea     rsi, [fb]
    mov     edx, W*H*3
    call    file_write
    jmp     file_close

write_png:
    lea     rdi, [n_png]
    call    file_create
    lea     rsi, [pngbuf]
    mov     rdx, [png_len]
    call    file_write
    jmp     file_close

; ---------------------------------------------------------------------------
; PNG encoding
mk_crctab:
    xor     ecx, ecx
.n: mov     eax, ecx
    mov     edx, 8
.k: shr     eax, 1
    jnc     @f
    xor     eax, 0xEDB88320
@@: dec     edx
    jnz     .k
    mov     [crctab+rcx*4], eax
    inc     ecx
    cmp     ecx, 256
    jb      .n
    ret

; crc_calc: rsi -> data, ecx = length -> eax
crc_calc:
    mov     eax, 0xFFFFFFFF
.l: movzx   edx, byte [rsi]
    inc     rsi
    xor     dl, al
    movzx   edx, dl
    shr     eax, 8
    xor     eax, [crctab+rdx*4]
    dec     ecx
    jnz     .l
    not     eax
    ret

; adler32: rsi -> data, ecx = length -> eax
adler32:
    mov     edx, 1                      ; a
    xor     r9d, r9d                    ; b
.l: movzx   eax, byte [rsi]
    inc     rsi
    add     edx, eax
    cmp     edx, 65521
    jb      @f
    sub     edx, 65521
@@: add     r9d, edx
    cmp     r9d, 65521
    jb      @f
    sub     r9d, 65521
@@: dec     ecx
    jnz     .l
    shl     r9d, 16
    or      r9d, edx
    mov     eax, r9d
    ret

; put_be32: append eax big-endian at r15
put_be32:
    bswap   eax
    mov     [r15], eax
    add     r15, 4
    ret

make_png:
    ; raw scanlines: filter byte 0 + RGB row
    lea     rdi, [rawbuf]
    lea     rsi, [fb]
    mov     r8d, H
.r: mov     byte [rdi], 0
    inc     rdi
    mov     ecx, W*3
    rep     movsb
    dec     r8d
    jnz     .r
    lea     rsi, [rawbuf]
    mov     ecx, RAWLEN
    call    adler32
    mov     [adl], eax

    lea     r15, [pngbuf]
    mov     rax, 0x0A1A0A0D474E5089     ; signature
    mov     [r15], rax
    add     r15, 8

    mov     eax, 13                     ; IHDR
    call    put_be32
    mov     r12, r15
    mov     dword [r15], 'IHDR'
    add     r15, 4
    mov     eax, W
    call    put_be32
    mov     eax, H
    call    put_be32
    mov     dword [r15], 0x00000208     ; depth 8, colour type 2 (RGB), 0, 0
    mov     byte [r15+4], 0             ; no interlace
    add     r15, 5
    mov     rsi, r12
    mov     ecx, 17
    call    crc_calc
    call    put_be32

    mov     eax, IDATLEN                ; IDAT
    call    put_be32
    mov     r12, r15
    mov     dword [r15], 'IDAT'
    add     r15, 4
    mov     word [r15], 0x0178          ; zlib header 78 01
    add     r15, 2
    lea     rsi, [rawbuf]
    mov     r13d, RAWLEN
.b: mov     ecx, 65535
    xor     eax, eax                    ; BFINAL = 0
    cmp     r13d, 65535
    ja      @f
    mov     ecx, r13d
    mov     eax, 1                      ; last block
@@: mov     [r15], al
    mov     [r15+1], cx                 ; LEN
    mov     edx, ecx
    not     edx
    mov     [r15+3], dx                 ; NLEN
    add     r15, 5
    sub     r13d, ecx
    mov     rdi, r15
    rep     movsb
    mov     r15, rdi
    test    r13d, r13d
    jnz     .b
    mov     eax, [adl]
    call    put_be32
    mov     rsi, r12
    mov     rcx, r15
    sub     rcx, r12
    call    crc_calc
    call    put_be32

    xor     eax, eax                    ; IEND
    call    put_be32
    mov     dword [r15], 'IEND'
    add     r15, 4
    mov     eax, 0xAE426082
    call    put_be32

    lea     rax, [pngbuf]
    sub     r15, rax
    mov     [png_len], r15
    ret

; ---------------------------------------------------------------------------
segment readable writeable

n_ppm:    db 'out.ppm', 0
n_png:    db 'out.png', 0
ppm_hdr:  db 'P6', 10, '1920 1080', 10, '255', 10
ppm_hdr_n = $ - ppm_hdr
s_done:   db 'wrote out.ppm and out.png', 10
s_done_n = $ - s_done

align 16
c_one:        splat 1.0
c_big:        splat 1.0e30
c_eps:        splat 0.001
c_negeps:     splat -0.000001
c_quarter:    splat 0.25
c_255:        splat 255.0
c_attk:       splat 0.03                ; light falloff: 1 / (1 + k d^2)
c_spec:       splat 0.45
c_minw:       splat 0.02
c_amb:        vec 0.10, 0.12, 0.10      ; ambient
c_mask3:      dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0
c_absmask:    splat 0x7FFFFFFF
c_signmask:   splat 0x80000000
c_cam:        vec 0.0, 1.7, -6.3

; ---- lights: position, colour ----
lights:
    light  0.3, 4.2, -4.2,   0.85, 0.85, 0.78     ; white, ceiling, towards the camera
    light -3.4, 2.4,  1.8,   1.60, 0.35, 2.20     ; purple
    light  3.4, 2.2, -1.6,   0.30, 2.00, 0.40     ; green

; ---- room: floor, ceiling, left, right, back, front (inward normals) ----
planes:
    plane  0.0,  1.0,  0.0,   0.0,   0.90,0.90,0.85,  0.12,0.14,0.12,  0.25   ; floor
    plane  0.0, -1.0,  0.0,  -4.5,   0.75,0.80,0.75,  0.75,0.80,0.75,  0.0    ; ceiling
    plane  1.0,  0.0,  0.0,  -4.5,   0.16,0.55,0.24,  0.16,0.55,0.24,  0.0    ; left wall
    plane -1.0,  0.0,  0.0,  -4.5,   0.16,0.55,0.24,  0.16,0.55,0.24,  0.0    ; right wall
    plane  0.0,  0.0, -1.0,  -5.5,   0.16,0.55,0.24,  0.16,0.55,0.24,  0.0    ; back wall
    plane  0.0,  0.0,  1.0,  -7.0,   0.16,0.55,0.24,  0.16,0.55,0.24,  0.0    ; front wall

; ---- spheres: centre, r^2, colour, reflectivity ----
spheres:
    sphere  0.0, 1.0,  2.2,   1.0,    0.85, 0.15, 0.15,   0.25
    sphere -2.5, 0.7,  0.6,   0.49,   0.15, 0.70, 0.25,   0.10
    sphere  2.7, 0.9,  1.8,   0.81,   0.95, 0.95, 1.00,   0.85
    sphere -0.9, 0.4, -1.4,   0.16,   0.20, 0.40, 1.00,   0.20

; ---- cube: yawed 30 degrees, half-size 0.6, resting on the floor ----
cube_c:     vec 1.3, 0.6, -1.2
cube_h:     splat 0.6
cube_col:   vec 0.95, 0.60, 0.10
cube_refl:  splat 0.10
cube_rotF:                              ; world -> local
    vec  0.8660254, 0.0, -0.5
    vec  0.0,       1.0,  0.0
    vec  0.5,       0.0,  0.8660254
cube_rotB:                              ; local -> world
    vec  0.8660254, 0.0,  0.5
    vec  0.0,       1.0,  0.0
    vec -0.5,       0.0,  0.8660254

c_q:      dd 0.25
c_h:      dd 0.5
c_halfw:  dd 960.0
c_halfh:  dd 540.0
c_scale:  dd 0.00083333333            ; 2*tan(vfov/2)/H, tan = 0.45
c_nscale: dd -0.00083333333
c_tilt:   dd -0.10                    ; look slightly down

align 16
tls:      rb TLSSIZE*MAXTHREADS
stacks:   rb STACKSZ*MAXTHREADS
cpumask:  rb 1024
next_row: rd 1
finished: rd 1
nthreads: rd 1
adl:      rd 1
fd:       rd 1
png_len:  rq 1
crctab:   rd 256
fb:       rb W*H*3
rawbuf:   rb RAWLEN
pngbuf:   rb RAWLEN + NBLK*5 + 256

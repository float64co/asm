; gl.asm - OpenGL demo: lit spinning cube, orbiting purple + green lights
; fasm, Linux x86-64.  Dynamically linked against libX11, libGL, libm, libc
; (fasm makes the object, ld links it - see the Makefile).
;
; Fixed-function OpenGL (no shaders): GLX window, 3 lights, per-vertex
; lighting, depth test, optional 4x MSAA.  Camera slowly orbits the scene.
;
;   ./gl            run (Esc / q / close the window to quit)
;   ./gl --shot     render 40 frames, save shot.ppm (bottom-up), and exit
;   ./gl --shot x1 y1 x2 y2   same, but first inject a left-button press at
;                   (x1,y1), a drag to (x2,y2) and a release (self-test)
;
; Mouse: drag a cube to slide it over the floor (it lifts while held and
;        settles when dropped); drag empty space to orbit the camera;
;        scroll wheel zooms; r resets cubes and camera.
;
; SysV ABI: args in rdi,rsi,rdx,rcx,r8,r9 / xmm0-7; rsp must be 16-byte
; aligned at every call.  Every function below does `push rbp` first, which
; makes rsp 16-aligned, and pushes registers only in pairs.

format ELF64

public _start

macro ext [n] { extrn n }
ext XOpenDisplay, XDefaultScreen, XRootWindow, XCreateColormap, XCreateWindow
ext XMapWindow, XStoreName, XInternAtom, XSetWMProtocols, XPending, XNextEvent
ext XLookupKeysym, XCloseDisplay
ext glXChooseVisual, glXCreateContext, glXMakeCurrent, glXSwapBuffers, glXDestroyContext
ext glClearColor, glClear, glEnable, glDisable, glMatrixMode, glLoadIdentity
ext glFrustum, glViewport, glLightfv, glLightf, glLightModelfv, glMaterialfv
ext glMaterialf, glColor3f, glColor3fv, glNormal3f, glNormal3fv, glVertex3f
ext glVertex3fv, glBegin, glEnd, glPushMatrix, glPopMatrix, glTranslatef
ext glRotatef, glScalef, glReadPixels, glPixelStorei, glGetString
ext sinf, cosf, clock_gettime, usleep, puts, exit, atoi

; load a float literal into an xmm register (clobbers eax)
macro fl reg, v {
    mov     eax, v
    movd    reg, eax
}

GL_DEPTH_TEST   = 0x0B71
GL_LIGHTING     = 0x0B50
GL_LIGHT0       = 0x4000
GL_COLOR_MAT    = 0x0B57
GL_NORMALIZE    = 0x0BA1
GL_POSITION     = 0x1203
GL_DIFFUSE      = 0x1201
GL_SPECULAR     = 0x1202
GL_CONST_ATT    = 0x1207
GL_LIN_ATT      = 0x1208
GL_QUAD_ATT     = 0x1209
GL_QUADS        = 7
GL_PROJECTION   = 0x1701
GL_MODELVIEW    = 0x1700
GL_FRONT_BACK   = 0x0408
GL_SHININESS    = 0x1601
GL_LMODEL_AMB   = 0x0B53

FLOOR_N         = 40                    ; floor is FLOOR_N x FLOOR_N tiles
EVMASK          = 0x2200D               ; Key/ButtonPress, ButtonRelease, ButtonMotion, StructureNotify

section '.text' executable

_start:
    mov     rax, [rsp]
    mov     [argc], rax
    lea     rax, [rsp+8]
    mov     [argv], rax
    and     rsp, -16
    call    main
    mov     edi, eax
    call    exit

; ---------------------------------------------------------------------------
main:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12                         ; rsp now 16-aligned

    xor     edi, edi
    call    XOpenDisplay
    test    rax, rax
    jnz     .have_dpy
    lea     rdi, [s_nodisp]
    call    puts
    mov     eax, 1
    jmp     .out
.have_dpy:
    mov     [dpy], rax
    mov     rdi, rax
    call    XDefaultScreen
    mov     [screen], eax
    mov     rdi, [dpy]
    mov     esi, [screen]
    call    XRootWindow
    mov     [root], rax

    mov     rdi, [dpy]                  ; prefer 4x MSAA, fall back to plain
    mov     esi, [screen]
    lea     rdx, [attr_msaa]
    call    glXChooseVisual
    test    rax, rax
    jnz     .have_vi
    mov     rdi, [dpy]
    mov     esi, [screen]
    lea     rdx, [attr_plain]
    call    glXChooseVisual
    test    rax, rax
    jnz     .have_vi
    lea     rdi, [s_novis]
    call    puts
    mov     eax, 1
    jmp     .out
.have_vi:
    mov     [vi], rax
    mov     rdi, [dpy]
    mov     rsi, [root]
    mov     rdx, [rax]                  ; vi->visual
    xor     ecx, ecx                    ; AllocNone
    call    XCreateColormap
    mov     [setattr+96], rax           ; colormap
    mov     qword [setattr+72], EVMASK  ; event_mask

    mov     rdi, [dpy]
    mov     rsi, [root]
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, 1280
    mov     r9d, 720
    mov     rax, [vi]
    lea     r10, [setattr]
    push    r10                         ; attributes
    push    0x2800                      ; CWEventMask | CWColormap
    push    qword [rax]                 ; visual
    push    1                           ; InputOutput
    mov     r11d, [rax+20]
    push    r11                         ; depth
    push    0                           ; border width
    call    XCreateWindow
    add     rsp, 48
    mov     [win], rax
    mov     dword [curw], 1280
    mov     dword [curh], 720

    mov     rdi, [dpy]
    mov     rsi, [win]
    lea     rdx, [s_title]
    call    XStoreName
    mov     rdi, [dpy]
    lea     rsi, [s_wmdel]
    xor     edx, edx
    call    XInternAtom
    mov     [wmdel], rax
    mov     rdi, [dpy]
    mov     rsi, [win]
    lea     rdx, [wmdel]
    mov     ecx, 1
    call    XSetWMProtocols
    mov     rdi, [dpy]
    mov     rsi, [win]
    call    XMapWindow

    mov     rdi, [dpy]
    mov     rsi, [vi]
    xor     edx, edx
    mov     ecx, 1                      ; direct rendering
    call    glXCreateContext
    mov     [ctx], rax
    mov     rdi, [dpy]
    mov     rsi, [win]
    mov     rdx, rax
    call    glXMakeCurrent

    mov     edi, 0x1F01                 ; GL_RENDERER
    call    glGetString
    mov     rdi, rax
    call    puts

    call    gl_init
    cmp     qword [argc], 6             ; --shot x1 y1 x2 y2
    jb      .noargs
    mov     rax, [argv]
    mov     rdi, [rax+16]
    call    atoi
    mov     [tx1], eax
    mov     rax, [argv]
    mov     rdi, [rax+24]
    call    atoi
    mov     [ty1], eax
    mov     rax, [argv]
    mov     rdi, [rax+32]
    call    atoi
    mov     [tx2], eax
    mov     rax, [argv]
    mov     rdi, [rax+40]
    call    atoi
    mov     [ty2], eax
.noargs:
    mov     dword [needproj], 1
    mov     dword [running], 1
    xor     ebx, ebx                    ; frame counter

.loop:
    cmp     dword [running], 0
    je      .done
.ev:
    mov     rdi, [dpy]
    call    XPending
    test    eax, eax
    jz      .noev
    mov     rdi, [dpy]
    lea     rsi, [ev]
    call    XNextEvent
    mov     eax, [ev]
    cmp     eax, 2                      ; KeyPress
    je      .key
    cmp     eax, 33                     ; ClientMessage
    je      .msg
    cmp     eax, 22                     ; ConfigureNotify
    je      .cfg
    cmp     eax, 4                      ; ButtonPress
    je      .bp
    cmp     eax, 5                      ; ButtonRelease
    je      .br
    cmp     eax, 6                      ; MotionNotify
    je      .bm
    jmp     .ev
.bp:
    call    on_press
    jmp     .ev
.br:
    call    on_release
    jmp     .ev
.bm:
    call    on_motion
    jmp     .ev
.key:
    lea     rdi, [ev]
    xor     esi, esi
    call    XLookupKeysym
    cmp     rax, 0xFF1B                 ; Escape
    je      .quit
    cmp     rax, 'q'
    je      .quit
    cmp     rax, 'r'
    jne     .ev
    call    reset_all
    jmp     .ev
.msg:
    mov     rax, [ev+56]
    cmp     rax, [wmdel]
    je      .quit
    jmp     .ev
.cfg:
    mov     eax, [ev+56]
    mov     edx, [ev+60]
    test    eax, eax
    jz      .ev
    test    edx, edx
    jz      .ev
    mov     [curw], eax
    mov     [curh], edx
    mov     dword [needproj], 1
    jmp     .ev
.quit:
    mov     dword [running], 0
    jmp     .loop
.noev:
    cmp     dword [needproj], 0
    je      @f
    call    setup_proj
    mov     dword [needproj], 0
@@:
    call    draw_frame
    mov     rdi, [dpy]
    mov     rsi, [win]
    call    glXSwapBuffers
    inc     ebx
    cmp     qword [argc], 2
    jb      .sleep
    cmp     qword [argc], 6
    jb      .nosyn
    cmp     ebx, 10                     ; synthetic press, drag, release
    jne     @f
    mov     eax, [tx1]
    mov     [ev+64], eax
    mov     eax, [ty1]
    mov     [ev+68], eax
    mov     dword [ev+84], 1
    call    on_press
@@: cmp     ebx, 12
    jne     @f
    mov     eax, [tx2]
    mov     [ev+64], eax
    mov     eax, [ty2]
    mov     [ev+68], eax
    call    on_motion
@@: cmp     ebx, 14
    jne     @f
    mov     dword [ev+84], 1
    call    on_release
@@:
.nosyn:
    cmp     ebx, 40                     ; --shot: let the window settle
    jb      .sleep
    call    shot
    jmp     .done
.sleep:
    mov     edi, 4000
    call    usleep
    jmp     .loop

.done:
    mov     rdi, [dpy]
    xor     esi, esi
    xor     edx, edx
    call    glXMakeCurrent
    mov     rdi, [dpy]
    mov     rsi, [ctx]
    call    glXDestroyContext
    mov     rdi, [dpy]
    call    XCloseDisplay
    xor     eax, eax
.out:
    pop     r12
    pop     rbx
    pop     rbp
    ret

; ---------------------------------------------------------------------------
; one-time GL state: depth, lighting, three lights, material
gl_init:
    push    rbp
    mov     rbp, rsp
    fl      xmm0, 0.015
    fl      xmm1, 0.02
    fl      xmm2, 0.04
    fl      xmm3, 1.0
    call    glClearColor
    mov     edi, GL_DEPTH_TEST
    call    glEnable
    mov     edi, GL_LIGHTING
    call    glEnable
    mov     edi, GL_COLOR_MAT
    call    glEnable
    mov     edi, GL_NORMALIZE
    call    glEnable
    mov     edi, GL_LMODEL_AMB
    lea     rsi, [c_ambient]
    call    glLightModelfv
    mov     edi, GL_FRONT_BACK
    mov     esi, GL_SPECULAR
    lea     rdx, [c_matspec]
    call    glMaterialfv
    mov     edi, GL_FRONT_BACK
    mov     esi, GL_SHININESS
    fl      xmm0, 48.0
    call    glMaterialf

    xor     ebx, ebx                    ; light index (rbx is saved by main? no: save)
.l: lea     rax, [lcol]
    imul    ecx, ebx, 16
    add     rax, rcx
    mov     [tmpp], rax
    lea     edi, [GL_LIGHT0 + rbx]
    mov     esi, GL_DIFFUSE
    mov     rdx, [tmpp]
    call    glLightfv
    lea     edi, [GL_LIGHT0 + rbx]
    mov     esi, GL_SPECULAR
    mov     rdx, [tmpp]
    call    glLightfv
    lea     edi, [GL_LIGHT0 + rbx]
    mov     esi, GL_CONST_ATT
    fl      xmm0, 1.0
    call    glLightf
    lea     edi, [GL_LIGHT0 + rbx]
    mov     esi, GL_LIN_ATT
    fl      xmm0, 0.02
    call    glLightf
    lea     edi, [GL_LIGHT0 + rbx]
    mov     esi, GL_QUAD_ATT
    fl      xmm0, 0.012
    call    glLightf
    lea     edi, [GL_LIGHT0 + rbx]
    call    glEnable
    inc     ebx
    cmp     ebx, 3
    jb      .l
    pop     rbp
    ret

; viewport + projection from [curw] x [curh]
setup_proj:
    push    rbp
    mov     rbp, rsp
    xor     edi, edi
    xor     esi, esi
    mov     edx, [curw]
    mov     ecx, [curh]
    call    glViewport
    mov     edi, GL_PROJECTION
    call    glMatrixMode
    call    glLoadIdentity
    cvtsi2sd xmm0, dword [curw]
    cvtsi2sd xmm1, dword [curh]
    divsd   xmm0, xmm1                  ; aspect
    movsd   xmm3, [d_top]
    movapd  xmm1, xmm3
    mulsd   xmm1, xmm0                  ; right = top * aspect
    xorpd   xmm0, xmm0
    subsd   xmm0, xmm1                  ; left
    xorpd   xmm2, xmm2
    subsd   xmm2, xmm3                  ; bottom
    movsd   xmm4, [d_near]
    movsd   xmm5, [d_far]
    call    glFrustum
    mov     edi, GL_MODELVIEW
    call    glMatrixMode
    pop     rbp
    ret

; time in seconds since the first frame -> [t] (fixed in --shot mode)
get_time:
    push    rbp
    mov     rbp, rsp
    cmp     qword [argc], 2
    jb      .live
    fl      xmm0, 6.3
    movss   [t], xmm0
    pop     rbp
    ret
.live:
    mov     edi, 1                      ; CLOCK_MONOTONIC
    lea     rsi, [ts]
    call    clock_gettime
    cvtsi2sd xmm0, qword [ts]
    cvtsi2sd xmm1, qword [ts+8]
    divsd   xmm1, [d_1e9]
    addsd   xmm0, xmm1
    cmp     dword [t0set], 0
    jne     @f
    movsd   [t0], xmm0
    mov     dword [t0set], 1
@@: subsd   xmm0, [t0]
    cvtsd2ss xmm0, xmm0
    movss   [t], xmm0
    pop     rbp
    ret

; ---------------------------------------------------------------------------
; unit cube (+-0.5) centred at the origin, per-face normals
draw_cube:
    push    rbp
    mov     rbp, rsp
    push    r12
    push    r13
    mov     edi, GL_QUADS
    call    glBegin
    lea     r12, [cube]
    mov     r13d, 6
.f: mov     rdi, r12
    call    glNormal3fv
    lea     rdi, [r12+12]
    call    glVertex3fv
    lea     rdi, [r12+24]
    call    glVertex3fv
    lea     rdi, [r12+36]
    call    glVertex3fv
    lea     rdi, [r12+48]
    call    glVertex3fv
    add     r12, 60
    dec     r13d
    jnz     .f
    call    glEnd
    pop     r13
    pop     r12
    pop     rbp
    ret

; checkered floor, tessellated so per-vertex lighting shows the light pools
draw_floor:
    push    rbp
    mov     rbp, rsp
    push    r12
    push    r13
    fl      xmm0, 0.0
    fl      xmm1, 1.0
    fl      xmm2, 0.0
    call    glNormal3f
    mov     edi, GL_QUADS
    call    glBegin
    xor     r12d, r12d                  ; iz
.z: xor     r13d, r13d                  ; ix
.x: ; tile colour by parity
    mov     eax, r12d
    add     eax, r13d
    test    al, 1
    jz      .a
    fl      xmm0, 0.12
    fl      xmm1, 0.13
    fl      xmm2, 0.15
    jmp     .c
.a: fl      xmm0, 0.88
    fl      xmm1, 0.88
    fl      xmm2, 0.84
.c: call    glColor3f
    lea     eax, [r13 - FLOOR_N/2]
    cvtsi2ss xmm0, eax
    mulss   xmm0, [c_tile]
    movss   [fx0], xmm0
    addss   xmm0, [c_tile]
    movss   [fx1], xmm0
    lea     eax, [r12 - FLOOR_N/2]
    cvtsi2ss xmm0, eax
    mulss   xmm0, [c_tile]
    movss   [fz0], xmm0
    addss   xmm0, [c_tile]
    movss   [fz1], xmm0
    movss   xmm0, [fx0]
    xorps   xmm1, xmm1
    movss   xmm2, [fz0]
    call    glVertex3f
    movss   xmm0, [fx0]
    xorps   xmm1, xmm1
    movss   xmm2, [fz1]
    call    glVertex3f
    movss   xmm0, [fx1]
    xorps   xmm1, xmm1
    movss   xmm2, [fz1]
    call    glVertex3f
    movss   xmm0, [fx1]
    xorps   xmm1, xmm1
    movss   xmm2, [fz0]
    call    glVertex3f
    inc     r13d
    cmp     r13d, FLOOR_N
    jb      .x
    inc     r12d
    cmp     r12d, FLOOR_N
    jb      .z
    call    glEnd
    pop     r13
    pop     r12
    pop     rbp
    ret

; ---------------------------------------------------------------------------
; light positions (world space) from [t]
calc_lights:
    push    rbp
    mov     rbp, rsp
    ; purple: circle radius 4.5, height 2.2 + bob
    movss   xmm0, [t]
    mulss   xmm0, [c_w0]
    movss   [ang], xmm0
    call    cosf
    mulss   xmm0, [c_r0]
    movss   [p0], xmm0
    movss   xmm0, [ang]
    call    sinf
    mulss   xmm0, [c_r0]
    movss   [p0+8], xmm0
    movss   xmm0, [t]
    mulss   xmm0, [c_bobw]
    call    sinf
    mulss   xmm0, [c_bob]
    addss   xmm0, [c_h0]
    movss   [p0+4], xmm0
    ; green: opposite phase, other speed and radius
    movss   xmm0, [t]
    mulss   xmm0, [c_w1]
    addss   xmm0, [c_pi]
    movss   [ang], xmm0
    call    cosf
    mulss   xmm0, [c_r1]
    movss   [p1], xmm0
    movss   xmm0, [ang]
    call    sinf
    mulss   xmm0, [c_r1]
    movss   [p1+8], xmm0
    movss   xmm0, [t]
    mulss   xmm0, [c_bobw]
    addss   xmm0, [c_pi]
    call    sinf
    mulss   xmm0, [c_bob]
    addss   xmm0, [c_h1]
    movss   [p1+4], xmm0
    pop     rbp
    ret

draw_frame:
    push    rbp
    mov     rbp, rsp
    push    r12
    push    r13
    call    get_time
    call    calc_lights

    mov     edi, 0x4100                 ; colour | depth
    call    glClear
    mov     edi, GL_MODELVIEW
    call    glMatrixMode
    call    glLoadIdentity
    cmp     dword [autocam], 0
    je      @f
    movss   xmm0, [t]
    mulss   xmm0, [c_camw]
    movss   [yaw], xmm0                 ; slow automatic orbit until you drag
@@: call    update_cubes
    fl      xmm0, 0.0
    fl      xmm1, -1.7
    xorps   xmm2, xmm2
    subss   xmm2, [camdist]
    call    glTranslatef
    movss   xmm0, [pitch]
    fl      xmm1, 1.0
    fl      xmm2, 0.0
    fl      xmm3, 0.0
    call    glRotatef
    movss   xmm0, [yaw]
    fl      xmm1, 0.0
    fl      xmm2, 1.0
    fl      xmm3, 0.0
    call    glRotatef

    mov     edi, GL_LIGHT0
    mov     esi, GL_POSITION
    lea     rdx, [p0]
    call    glLightfv
    mov     edi, GL_LIGHT0 + 1
    mov     esi, GL_POSITION
    lea     rdx, [p1]
    call    glLightfv
    mov     edi, GL_LIGHT0 + 2
    mov     esi, GL_POSITION
    lea     rdx, [p2]
    call    glLightfv

    call    draw_floor

    ; centre cube
    call    glPushMatrix
    movss   xmm0, [cube_pos]
    movss   xmm1, [cube_pos+4]
    movss   xmm2, [cube_pos+8]
    call    glTranslatef
    movss   xmm0, [t]
    mulss   xmm0, [c_spin]
    fl      xmm1, 0.3
    fl      xmm2, 1.0
    fl      xmm3, 0.2
    call    glRotatef
    fl      xmm0, 2.0
    fl      xmm1, 2.0
    fl      xmm2, 2.0
    call    glScalef
    fl      xmm0, 0.93
    fl      xmm1, 0.93
    fl      xmm2, 0.93
    call    glColor3f
    call    draw_cube
    call    glPopMatrix

    ; ring of six small cubes (positions come from update_cubes)
    xor     r12d, r12d
.r: call    glPushMatrix
    lea     eax, [r12+1]
    shl     eax, 4
    lea     rdx, [cube_pos]
    movss   xmm0, [rdx+rax]
    movss   xmm1, [rdx+rax+4]
    movss   xmm2, [rdx+rax+8]
    call    glTranslatef
    cvtsi2ss xmm0, r12d
    mulss   xmm0, [c_40]
    movss   xmm1, [t]
    mulss   xmm1, [c_60]
    addss   xmm0, xmm1
    fl      xmm1, 1.0
    fl      xmm2, 1.0
    fl      xmm3, 0.0
    call    glRotatef
    fl      xmm0, 0.6
    fl      xmm1, 0.6
    fl      xmm2, 0.6
    call    glScalef
    lea     rdi, [ringcol]
    imul    eax, r12d, 12
    add     rdi, rax
    call    glColor3fv
    call    draw_cube
    call    glPopMatrix
    inc     r12d
    cmp     r12d, 6
    jb      .r

    ; glowing markers where the two coloured lights are (unlit)
    mov     edi, GL_LIGHTING
    call    glDisable
    call    glPushMatrix
    movss   xmm0, [p0]
    movss   xmm1, [p0+4]
    movss   xmm2, [p0+8]
    call    glTranslatef
    fl      xmm0, 0.3
    fl      xmm1, 0.3
    fl      xmm2, 0.3
    call    glScalef
    fl      xmm0, 0.95
    fl      xmm1, 0.4
    fl      xmm2, 1.0
    call    glColor3f
    call    draw_cube
    call    glPopMatrix
    call    glPushMatrix
    movss   xmm0, [p1]
    movss   xmm1, [p1+4]
    movss   xmm2, [p1+8]
    call    glTranslatef
    fl      xmm0, 0.3
    fl      xmm1, 0.3
    fl      xmm2, 0.3
    call    glScalef
    fl      xmm0, 0.4
    fl      xmm1, 1.0
    fl      xmm2, 0.5
    call    glColor3f
    call    draw_cube
    call    glPopMatrix
    mov     edi, GL_LIGHTING
    call    glEnable

    pop     r13
    pop     r12
    pop     rbp
    ret

; ---------------------------------------------------------------------------
; cube positions.  Index 0 = centre cube, 1..6 = ring.  A cube that has been
; grabbed becomes "free": it keeps its position (the ring/home animation
; stops driving it) and eases to its resting height; while held it hovers.
update_cubes:
    push    rbp
    mov     rbp, rsp
    push    r12
    push    r13
    cmp     dword [cube_free], 0
    jne     .ring0
    mov     dword [cube_pos], 0.0
    mov     dword [cube_pos+4], 1.5
    mov     dword [cube_pos+8], 0.0
.ring0:
    xor     r12d, r12d
.ring:
    cvtsi2ss xmm0, r12d
    mulss   xmm0, [c_60deg]
    movss   xmm1, [t]
    mulss   xmm1, [c_half]
    addss   xmm0, xmm1
    movss   [ang], xmm0
    call    cosf
    mulss   xmm0, [c_ringr]
    movss   [rx], xmm0
    movss   xmm0, [ang]
    call    sinf
    mulss   xmm0, [c_ringr]
    movss   [rz], xmm0
    cvtsi2ss xmm0, r12d
    movss   xmm1, [t]
    addss   xmm1, xmm1
    addss   xmm0, xmm1
    call    sinf
    mulss   xmm0, [c_ringbob]
    addss   xmm0, [c_ringy]
    movss   [ry], xmm0
    lea     eax, [r12+1]
    lea     rdx, [cube_free]
    cmp     dword [rdx+rax*4], 0
    jne     .skip
    shl     eax, 4
    lea     rdx, [cube_pos]
    movss   xmm0, [rx]
    movss   [rdx+rax], xmm0
    movss   xmm0, [ry]
    movss   [rdx+rax+4], xmm0
    movss   xmm0, [rz]
    movss   [rdx+rax+8], xmm0
.skip:
    inc     r12d
    cmp     r12d, 6
    jb      .ring
    ; free cubes ease toward their resting height (+hover while held)
    xor     r12d, r12d
.h: lea     rdx, [cube_free]
    cmp     dword [rdx+r12*4], 0
    je      .hn
    lea     rdx, [cube_rest]
    movss   xmm0, [rdx+r12*4]
    cmp     dword [grabbed], r12d
    jne     @f
    addss   xmm0, [c_hover]
@@: mov     eax, r12d
    shl     eax, 4
    lea     rdx, [cube_pos]
    movss   xmm1, [rdx+rax+4]
    subss   xmm0, xmm1
    mulss   xmm0, [c_ease]
    addss   xmm1, xmm0
    movss   [rdx+rax+4], xmm1
.hn:
    inc     r12d
    cmp     r12d, 7
    jb      .h
    pop     r13
    pop     r12
    pop     rbp
    ret

reset_all:
    push    rbp
    mov     rbp, rsp
    mov     dword [autocam], 1
    mov     dword [pitch], 20.0
    mov     dword [camdist], 11.0
    mov     dword [grabbed], -1
    mov     dword [dragmode], 0
    lea     rdi, [cube_free]
    xor     eax, eax
    mov     ecx, 7
    rep     stosd
    pop     rbp
    ret

; ---------------------------------------------------------------------------
; mouse -> world ray.  The camera is  T(0,-1.7,-dist) . Rx(pitch) . Ry(yaw),
; so a world point is  Ry(-yaw) . Rx(-pitch) . (eye - T).
cam_trig:
    push    rbp
    mov     rbp, rsp
    movss   xmm0, [pitch]
    mulss   xmm0, [c_d2r]
    movss   [tmpa], xmm0
    call    cosf
    movss   [cosP], xmm0
    movss   xmm0, [tmpa]
    call    sinf
    movss   [sinP], xmm0
    movss   xmm0, [yaw]
    mulss   xmm0, [c_d2r]
    movss   [tmpa], xmm0
    call    cosf
    movss   [cosY], xmm0
    movss   xmm0, [tmpa]
    call    sinf
    movss   [sinY], xmm0
    pop     rbp
    ret

; eye-space vector (xmm0,xmm1,xmm2) -> world-space (same registers)
rot_inv:
    movss   xmm3, xmm1                  ; vy
    movss   xmm4, xmm2                  ; vz
    movss   xmm5, xmm3
    mulss   xmm5, [cosP]
    movss   xmm6, xmm4
    mulss   xmm6, [sinP]
    addss   xmm5, xmm6                  ; y1 = vy c + vz s
    mulss   xmm4, [cosP]
    mulss   xmm3, [sinP]
    subss   xmm4, xmm3                  ; z1 = vz c - vy s
    movss   xmm6, xmm0
    mulss   xmm6, [cosY]
    movss   xmm7, xmm4
    mulss   xmm7, [sinY]
    subss   xmm6, xmm7                  ; x2 = x c - z1 s
    mulss   xmm0, [sinY]
    mulss   xmm4, [cosY]
    addss   xmm0, xmm4                  ; z2 = x s + z1 c
    movss   xmm2, xmm0
    movss   xmm0, xmm6
    movss   xmm1, xmm5
    ret

; [mx],[my] (pixels) -> [ray_o], [ray_d] in world space
unproject:
    push    rbp
    mov     rbp, rsp
    call    cam_trig
    cvtsi2ss xmm0, dword [mx]
    addss   xmm0, xmm0
    cvtsi2ss xmm1, dword [curw]
    divss   xmm0, xmm1
    subss   xmm0, [c_one]               ; ndc x
    cvtsi2ss xmm3, dword [my]
    addss   xmm3, xmm3
    cvtsi2ss xmm1, dword [curh]
    divss   xmm3, xmm1
    movss   xmm1, [c_one]
    subss   xmm1, xmm3
    movss   xmm3, xmm1                  ; ndc y
    cvtsi2ss xmm4, dword [curw]
    cvtsi2ss xmm5, dword [curh]
    divss   xmm4, xmm5                  ; aspect
    mulss   xmm0, [c_topf]
    mulss   xmm0, xmm4                  ; dir.x
    mulss   xmm3, [c_topf]
    movss   xmm1, xmm3                  ; dir.y
    movss   xmm2, [c_m1]                ; dir.z
    call    rot_inv
    movss   [ray_d], xmm0
    movss   [ray_d+4], xmm1
    movss   [ray_d+8], xmm2
    xorps   xmm0, xmm0
    movss   xmm1, [c_camy]
    movss   xmm2, [camdist]
    call    rot_inv
    movss   [ray_o], xmm0
    movss   [ray_o+4], xmm1
    movss   [ray_o+8], xmm2
    pop     rbp
    ret

; ray vs the horizontal plane y = xmm0 -> eax = 1 and [hitx],[hitz], or 0
ray_plane:
    movss   xmm1, [ray_d+4]
    comiss  xmm1, [c_negeps4]
    jae     .no
    subss   xmm0, [ray_o+4]
    divss   xmm0, xmm1                  ; t
    movss   xmm2, [ray_d]
    mulss   xmm2, xmm0
    addss   xmm2, [ray_o]
    movss   [hitx], xmm2
    movss   xmm2, [ray_d+8]
    mulss   xmm2, xmm0
    addss   xmm2, [ray_o+8]
    movss   [hitz], xmm2
    mov     eax, 1
    ret
.no:
    xor     eax, eax
    ret

; nearest cube (bounding sphere) under the current ray -> eax = index or -1
pick:
    push    rbp
    mov     rbp, rsp
    push    r12
    push    r13
    mov     r13d, -1
    mov     dword [bestt], 1.0e30
    xor     r12d, r12d
.l: mov     eax, r12d
    shl     eax, 4
    lea     rdx, [cube_pos]
    movss   xmm0, [ray_o]
    subss   xmm0, [rdx+rax]
    movss   xmm1, [ray_o+4]
    subss   xmm1, [rdx+rax+4]
    movss   xmm2, [ray_o+8]
    subss   xmm2, [rdx+rax+8]           ; oc = origin - centre
    movss   xmm3, xmm0
    mulss   xmm3, [ray_d]
    movss   xmm4, xmm1
    mulss   xmm4, [ray_d+4]
    addss   xmm3, xmm4
    movss   xmm4, xmm2
    mulss   xmm4, [ray_d+8]
    addss   xmm3, xmm4                  ; b = oc . d
    mulss   xmm0, xmm0
    mulss   xmm1, xmm1
    mulss   xmm2, xmm2
    addss   xmm0, xmm1
    addss   xmm0, xmm2
    lea     rcx, [cube_pickr]
    movss   xmm4, [rcx+r12*4]
    mulss   xmm4, xmm4
    subss   xmm0, xmm4                  ; c = oc.oc - r^2
    movss   xmm5, [ray_d]
    mulss   xmm5, xmm5
    movss   xmm6, [ray_d+4]
    mulss   xmm6, xmm6
    addss   xmm5, xmm6
    movss   xmm6, [ray_d+8]
    mulss   xmm6, xmm6
    addss   xmm5, xmm6                  ; a = d . d
    movss   xmm6, xmm3
    mulss   xmm6, xmm6
    mulss   xmm0, xmm5
    subss   xmm6, xmm0                  ; disc = b^2 - a c
    xorps   xmm7, xmm7
    comiss  xmm6, xmm7
    jb      .n
    sqrtss  xmm6, xmm6
    xorps   xmm7, xmm7
    subss   xmm7, xmm3
    subss   xmm7, xmm6
    divss   xmm7, xmm5                  ; t = (-b - sqrt) / a
    xorps   xmm0, xmm0
    comiss  xmm7, xmm0
    jbe     .n
    comiss  xmm7, [bestt]
    jae     .n
    movss   [bestt], xmm7
    mov     r13d, r12d
.n: inc     r12d
    cmp     r12d, 7
    jb      .l
    mov     eax, r13d
    pop     r13
    pop     r12
    pop     rbp
    ret

; ---------------------------------------------------------------------------
; mouse handlers; they read the XEvent in [ev]
on_press:
    push    rbp
    mov     rbp, rsp
    mov     eax, [ev+84]                ; button
    cmp     eax, 4
    je      .up
    cmp     eax, 5
    je      .down
    cmp     eax, 1
    jne     .ret
    mov     eax, [ev+64]
    mov     [mx], eax
    mov     [lastx], eax
    mov     eax, [ev+68]
    mov     [my], eax
    mov     [lasty], eax
    call    unproject
    call    pick
    test    eax, eax
    js      .cam
    mov     [grabbed], eax
    lea     rdx, [cube_free]
    mov     dword [rdx+rax*4], 1
    lea     rdx, [cube_rest]
    movss   xmm0, [rdx+rax*4]
    addss   xmm0, [c_hover]             ; drag plane = the height it hovers at
    call    ray_plane
    xorps   xmm0, xmm0
    movss   [goffx], xmm0
    movss   [goffz], xmm0
    test    eax, eax
    jz      .held
    mov     eax, [grabbed]              ; remember where on the cube we grabbed
    shl     eax, 4
    lea     rdx, [cube_pos]
    movss   xmm0, [rdx+rax]
    subss   xmm0, [hitx]
    movss   [goffx], xmm0
    movss   xmm0, [rdx+rax+8]
    subss   xmm0, [hitz]
    movss   [goffz], xmm0
.held:
    mov     dword [dragmode], 1
    jmp     .ret
.cam:
    mov     dword [dragmode], 2
    jmp     .ret
.up:
    movss   xmm0, [camdist]
    mulss   xmm0, [c_zin]
    maxss   xmm0, [c_dmin]
    movss   [camdist], xmm0
    jmp     .ret
.down:
    movss   xmm0, [camdist]
    mulss   xmm0, [c_zout]
    minss   xmm0, [c_dmax]
    movss   [camdist], xmm0
.ret:
    pop     rbp
    ret

on_release:
    mov     eax, [ev+84]
    cmp     eax, 1
    jne     .r
    mov     dword [grabbed], -1
    mov     dword [dragmode], 0
.r: ret

on_motion:
    push    rbp
    mov     rbp, rsp
    mov     eax, [ev+64]
    mov     [mx], eax
    mov     eax, [ev+68]
    mov     [my], eax
    cmp     dword [dragmode], 1
    je      .obj
    cmp     dword [dragmode], 2
    jne     .ret
    cvtsi2ss xmm0, dword [mx]           ; camera drag
    cvtsi2ss xmm1, dword [lastx]
    subss   xmm0, xmm1
    mulss   xmm0, [c_dragk]
    addss   xmm0, [yaw]
    movss   [yaw], xmm0
    cvtsi2ss xmm0, dword [my]
    cvtsi2ss xmm1, dword [lasty]
    subss   xmm0, xmm1
    mulss   xmm0, [c_dragk]
    addss   xmm0, [pitch]
    maxss   xmm0, [c_pmin]
    minss   xmm0, [c_pmax]
    movss   [pitch], xmm0
    mov     eax, [mx]
    mov     [lastx], eax
    mov     eax, [my]
    mov     [lasty], eax
    mov     dword [autocam], 0
    jmp     .ret
.obj:
    call    unproject
    mov     eax, [grabbed]
    lea     rdx, [cube_rest]
    movss   xmm0, [rdx+rax*4]
    addss   xmm0, [c_hover]
    call    ray_plane
    test    eax, eax
    jz      .ret
    movss   xmm0, [hitx]
    addss   xmm0, [goffx]
    maxss   xmm0, [c_lim_n]
    minss   xmm0, [c_lim]
    movss   xmm1, [hitz]
    addss   xmm1, [goffz]
    maxss   xmm1, [c_lim_n]
    minss   xmm1, [c_lim]
    mov     eax, [grabbed]
    shl     eax, 4
    lea     rdx, [cube_pos]
    movss   [rdx+rax], xmm0
    movss   [rdx+rax+8], xmm1
.ret:
    pop     rbp
    ret

; ---------------------------------------------------------------------------
; --shot: read the framebuffer and write shot.ppm (rows are bottom-up)
shot:
    push    rbp
    mov     rbp, rsp
    push    r12
    push    r13
    mov     edi, 0x0D05                 ; GL_PACK_ALIGNMENT
    mov     esi, 1
    call    glPixelStorei
    xor     edi, edi
    xor     esi, esi
    mov     edx, [curw]
    mov     ecx, [curh]
    mov     r8d, 0x1907                 ; GL_RGB
    mov     r9d, 0x1401                 ; GL_UNSIGNED_BYTE
    sub     rsp, 8
    lea     rax, [pix]
    push    rax                         ; 7th argument
    call    glReadPixels
    add     rsp, 16

    ; header "P6\n<w> <h>\n255\n"
    lea     r12, [hdr]
    mov     word [r12], 0x3650          ; "P6"
    mov     byte [r12+2], 10
    add     r12, 3
    mov     eax, [curw]
    call    put_dec
    mov     byte [r12], ' '
    inc     r12
    mov     eax, [curh]
    call    put_dec
    mov     dword [r12], 0x35320A       ; "\n25"
    mov     dword [r12+3], 0x0A35       ; "5\n"
    add     r12, 5
    lea     rax, [hdr]
    sub     r12, rax                    ; header length

    mov     eax, 2                      ; open
    lea     rdi, [s_shot]
    mov     esi, 0x241
    mov     edx, 0x1A4
    syscall
    mov     r13, rax
    mov     eax, 1                      ; write header
    mov     rdi, r13
    lea     rsi, [hdr]
    mov     rdx, r12
    syscall
    mov     eax, [curw]
    imul    eax, [curh]
    imul    rdx, rax, 3
    lea     rsi, [pix]
    mov     rdi, r13
.w: test    rdx, rdx
    jle     .d
    mov     eax, 1
    syscall
    test    rax, rax
    jle     .d
    add     rsi, rax
    sub     rdx, rax
    jmp     .w
.d: mov     eax, 3
    mov     rdi, r13
    syscall
    lea     rdi, [s_saved]
    call    puts
    pop     r13
    pop     r12
    pop     rbp
    ret

; put_dec: append eax in decimal at r12.  clobbers rax, rcx, rdx, r8
put_dec:
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
    mov     [r12], al
    inc     r12
    dec     ecx
    jnz     .w
    ret

; ---------------------------------------------------------------------------
section '.data' writeable align 16

s_nodisp: db 'cannot open X display (is WSLg / DISPLAY set up?)', 0
s_novis:  db 'no suitable GLX visual', 0
s_title:  db 'fasm OpenGL demo - By Float64', 0
s_wmdel:  db 'WM_DELETE_WINDOW', 0
s_shot:   db 'shot.ppm', 0
s_saved:  db 'saved shot.ppm', 0

align 4
attr_msaa:  dd 4, 5, 12, 24, 100000, 1, 100001, 4, 0
attr_plain: dd 4, 5, 12, 24, 0

align 16
c_ambient:  dd 0.11, 0.13, 0.12, 1.0
c_matspec:  dd 0.55, 0.55, 0.55, 1.0
; light colours: purple, green, dim white
lcol:       dd 1.50, 0.30, 1.70, 1.0
            dd 0.30, 1.60, 0.45, 1.0
            dd 0.65, 0.65, 0.60, 1.0
p0:         dd 4.5, 2.2, 0.0, 1.0
p1:         dd -5.5, 1.8, 0.0, 1.0
p2:         dd 0.0, 7.0, 0.0, 1.0
ringcol:    dd 1.00, 0.35, 0.30
            dd 1.00, 0.70, 0.20
            dd 0.90, 0.90, 0.30
            dd 0.30, 1.00, 0.50
            dd 0.30, 0.70, 1.00
            dd 0.80, 0.40, 1.00

; cube faces: normal, then 4 vertices
cube:
    dd  0.0,  0.0,  1.0,   -0.5,-0.5, 0.5,   0.5,-0.5, 0.5,   0.5, 0.5, 0.5,  -0.5, 0.5, 0.5
    dd  0.0,  0.0, -1.0,    0.5,-0.5,-0.5,  -0.5,-0.5,-0.5,  -0.5, 0.5,-0.5,   0.5, 0.5,-0.5
    dd  1.0,  0.0,  0.0,    0.5,-0.5, 0.5,   0.5,-0.5,-0.5,   0.5, 0.5,-0.5,   0.5, 0.5, 0.5
    dd -1.0,  0.0,  0.0,   -0.5,-0.5,-0.5,  -0.5,-0.5, 0.5,  -0.5, 0.5, 0.5,  -0.5, 0.5,-0.5
    dd  0.0,  1.0,  0.0,   -0.5, 0.5, 0.5,   0.5, 0.5, 0.5,   0.5, 0.5,-0.5,  -0.5, 0.5,-0.5
    dd  0.0, -1.0,  0.0,   -0.5,-0.5,-0.5,   0.5,-0.5,-0.5,   0.5,-0.5, 0.5,  -0.5,-0.5, 0.5

c_tile:   dd 0.4
c_half:   dd 0.5
c_w0:     dd 0.9
c_r0:     dd 4.5
c_h0:     dd 2.3
c_w1:     dd -0.65
c_r1:     dd 5.5
c_h1:     dd 1.8
c_bobw:   dd 1.7
c_bob:    dd 0.6
c_pi:     dd 3.14159265
c_camw:   dd 7.0
c_spin:   dd 35.0
c_60deg:  dd 1.04719755
c_ringr:  dd 3.2
c_ringy:  dd 0.6
c_ringbob: dd 0.35
c_40:     dd 40.0
c_60:     dd 60.0
c_one:    dd 1.0
c_m1:     dd -1.0
c_topf:   dd 0.46630766               ; tan(25 deg), as in setup_proj
c_d2r:    dd 0.0174532925
c_camy:   dd 1.7
c_negeps4: dd -0.0001
c_dragk:  dd 0.35                     ; degrees per pixel
c_pmin:   dd 3.0
c_pmax:   dd 88.0
c_zin:    dd 0.9
c_zout:   dd 1.1
c_dmin:   dd 4.0
c_dmax:   dd 30.0
c_hover:  dd 0.5
c_ease:   dd 0.2
c_lim:    dd 7.5
c_lim_n:  dd -7.5

yaw:      dd 0.0
pitch:    dd 20.0
camdist:  dd 11.0
autocam:  dd 1
grabbed:  dd -1
dragmode: dd 0

; resting height (half the cube size) and pick-sphere radius per cube
cube_rest:  dd 1.0, 0.3, 0.3, 0.3, 0.3, 0.3, 0.3
cube_pickr: dd 1.45, 0.55, 0.55, 0.55, 0.55, 0.55, 0.55

align 8
d_top:    dq 0.46630766               ; tan(25 deg)
d_near:   dq 1.0
d_far:    dq 60.0
d_1e9:    dq 1.0e9

section '.bss' writeable align 16

argc:     rq 1
dpy:      rq 1
root:     rq 1
win:      rq 1
ctx:      rq 1
vi:       rq 1
wmdel:    rq 1
tmpp:     rq 1
t0:       rq 1
ts:       rq 2
screen:   rd 1
curw:     rd 1
curh:     rd 1
needproj: rd 1
running:  rd 1
t0set:    rd 1
t:        rd 1
ang:      rd 1
fx0:      rd 1
fx1:      rd 1
fz0:      rd 1
fz1:      rd 1
rx:       rd 1
ry:       rd 1
rz:       rd 1
cube_free: rd 8
cube_pos:  rb 128
ray_o:    rd 4
ray_d:    rd 4
hitx:     rd 1
hitz:     rd 1
goffx:    rd 1
goffz:    rd 1
bestt:    rd 1
tmpa:     rd 1
cosP:     rd 1
sinP:     rd 1
cosY:     rd 1
sinY:     rd 1
mx:       rd 1
my:       rd 1
lastx:    rd 1
lasty:    rd 1
tx1:      rd 1
ty1:      rd 1
tx2:      rd 1
ty2:      rd 1
argv:     rq 1
setattr:  rb 112
ev:       rb 256
hdr:      rb 64
pix:      rb 1920*1200*3

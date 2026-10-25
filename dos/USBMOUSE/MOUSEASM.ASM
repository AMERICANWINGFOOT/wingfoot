; MOUSEASM.ASM - interrupt entry points for USBMOUSE (QuickC small model)
;
;   install_hooks()   hook INT 33h and INT 08h (saves the old vectors)
;   remove_hooks()    put them back; returns 0, or -1 if someone hooked after us
;   call_handler(ax,bx,cx,dx,si,di)   far-call the program's event handler (hfar)
;
; INT 33h: registers are copied to regs33[] (ax bx cx dx si di bp es ds),
;          mouse33(regs33) runs on stk33, results are copied back.
; INT 08h: the old handler runs first, then mouse_tick() on stk08
;          (skipped while INT 33h or a previous tick is still busy).
;
; Assemble: ml /c MOUSEASM.ASM  (MASM 6.11)  or  wasm -ms MOUSEASM.ASM
        .MODEL  SMALL, C
        .386
        PUBLIC  install_hooks, remove_hooks, call_handler
        PUBLIC  int33_entry, int08_entry

        EXTRN   mouse33:NEAR, mouse_tick:NEAR
        EXTRN   regs33:WORD, in33:BYTE, busy08:BYTE
        EXTRN   stk33:BYTE, stk08:BYTE, hfar:DWORD

STK33SZ EQU     1024
STK08SZ EQU     2048

        .DATA
s33_ss  dw      0
s33_sp  dw      0
s08_ss  dw      0
s08_sp  dw      0
old33   dd      0

        .CODE
sig     db      'USBMOUSE'                  ; signature in front of the handler
old08   dd      0                           ; in CS: reachable before DS is set

int33_entry PROC FAR
        push    ds
        push    es
        push    bp
        push    di
        push    si
        push    dx
        push    cx
        push    bx
        push    ax
        mov     bp, sp
        mov     ax, DGROUP
        mov     ds, ax
        mov     cx, 9                       ; copy caller's registers
        xor     si, si
cp_in:  mov     ax, ss:[bp+si]
        mov     regs33[si], ax
        add     si, 2
        loop    cp_in
        mov     in33, 1
        mov     s33_ss, ss
        mov     s33_sp, sp
        mov     ax, ds
        cli
        mov     ss, ax
        mov     sp, OFFSET stk33 + STK33SZ
        mov     es, ax
        cld
        mov     ax, OFFSET regs33
        push    ax
        call    mouse33
        add     sp, 2
        cli
        mov     ss, s33_ss
        mov     sp, s33_sp
        mov     bp, sp
        mov     cx, 9                       ; copy results back
        xor     si, si
cp_out: mov     ax, regs33[si]
        mov     ss:[bp+si], ax
        add     si, 2
        loop    cp_out
        mov     in33, 0
        pop     ax
        pop     bx
        pop     cx
        pop     dx
        pop     si
        pop     di
        pop     bp
        pop     es
        pop     ds
        iret
int33_entry ENDP

int08_entry PROC FAR
        pushf
        call    DWORD PTR cs:old08          ; BIOS tick + EOI first
        push    ds
        push    es
        pusha
        mov     ax, DGROUP
        mov     ds, ax
        cmp     busy08, 0
        jne     t_skip
        cmp     in33, 0
        jne     t_skip
        mov     busy08, 1
        mov     s08_ss, ss
        mov     s08_sp, sp
        cli
        mov     ss, ax
        mov     sp, OFFSET stk08 + STK08SZ
        mov     es, ax
        cld
        sti
        call    mouse_tick
        cli
        mov     ss, s08_ss
        mov     sp, s08_sp
        mov     busy08, 0
t_skip: popa
        pop     es
        pop     ds
        iret
int08_entry ENDP

install_hooks PROC USES si di es
        mov     ax, 3533h                   ; get INT 33h
        int     21h
        mov     WORD PTR old33, bx
        mov     WORD PTR old33+2, es
        mov     ax, 3508h                   ; get INT 08h
        int     21h
        mov     WORD PTR cs:old08, bx
        mov     WORD PTR cs:old08+2, es
        push    ds
        mov     ax, cs
        mov     ds, ax
        mov     dx, OFFSET int33_entry
        mov     ax, 2533h
        int     21h
        mov     dx, OFFSET int08_entry
        mov     ax, 2508h
        int     21h
        pop     ds
        ret
install_hooks ENDP

remove_hooks PROC USES si di es
        mov     ax, 3533h
        int     21h
        mov     ax, es
        mov     dx, cs
        cmp     ax, dx
        jne     rh_bad
        cmp     bx, OFFSET int33_entry
        jne     rh_bad
        mov     ax, 3508h
        int     21h
        mov     ax, es
        cmp     ax, dx
        jne     rh_bad
        cmp     bx, OFFSET int08_entry
        jne     rh_bad
        push    ds
        lds     dx, cs:old08
        mov     ax, 2508h
        int     21h
        pop     ds
        push    ds
        lds     dx, old33
        mov     ax, 2533h
        int     21h
        pop     ds
        xor     ax, ax
        ret
rh_bad: mov     ax, -1
        ret
remove_hooks ENDP

call_handler PROC USES si di, pax:WORD, pbx:WORD, pcx:WORD, pdx:WORD, psi:WORD, pdi:WORD
        push    ds
        push    es
        push    bp
        mov     ax, pax
        mov     bx, pbx
        mov     cx, pcx
        mov     dx, pdx
        mov     si, psi
        mov     di, pdi
        call    DWORD PTR hfar
        pop     bp
        pop     es
        pop     ds
        ret
call_handler ENDP

        END

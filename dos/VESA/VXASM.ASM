; VXASM.ASM - unreal mode + linear framebuffer helpers for VXDEMO
; Assemble with MASM 6.11:  ML /c /Cx VXASM.ASM
;
; Unreal mode: switch to protected mode just long enough to load FS
; and GS with a 4 GB data segment, then return to real mode.  The CPU
; keeps the 4 GB limit cached, so real-mode code can use 32-bit
; addresses through FS - e.g. MOV FS:[EDI],AX with EDI = F6000000h.
; DOS, the BIOS and QuickC keep running normally.
;
; Requires a real-mode CPU state: will not work under EMM386, QEMM
; or a Windows DOS box (V86 mode).  vx_unreal() returns 0 then.
;
; Small model, C calling convention.  Preserves BX SI DI ES.

        .MODEL  SMALL, C
        .386P

        PUBLIC  vx_unreal, vx_a20, vx_fill32, vx_copy, vx_copyin, vx_put16, vx_font8

        .DATA
        EVEN
gdt     dw      0, 0, 0, 0              ; null descriptor
        dw      0FFFFh, 0               ; selector 8: limit 0-15, base 0-15
        db      0, 92h, 8Fh, 0          ; base 16-23, data R/W, G=1 limit 16-19=F, base 24-31
gdtr    dw      15                      ; GDT limit
        dd      0                       ; GDT linear base (filled in at run time)
xmsent  dd      0

        .CODE

;---------------------------------------------------------------
; int vx_unreal(void)
;   Returns 1 on success, 0 if the CPU is in V86 mode (EMM386 etc).
;   Safe to call often; VXDEMO calls it every frame in case a BIOS
;   call reset the segment limits.
;---------------------------------------------------------------
vx_unreal PROC USES bx si di es
        smsw    ax
        test    al, 1                   ; PE set while "real" = V86 mode
        jz      vu_ok
        xor     ax, ax
        ret
vu_ok:
        pushf
        cli
        xor     eax, eax
        mov     ax, ds
        shl     eax, 4
        xor     edx, edx
        mov     dx, OFFSET gdt
        add     eax, edx
        mov     DWORD PTR gdtr+2, eax
        lgdt    FWORD PTR gdtr
        mov     eax, cr0
        or      al, 1
        mov     cr0, eax                ; protected mode
        jmp     SHORT vu_pm
vu_pm:  mov     bx, 8
        mov     fs, bx                  ; load 4 GB descriptor
        mov     gs, bx
        and     al, 0FEh
        mov     cr0, eax                ; back to real mode
        jmp     SHORT vu_rm
vu_rm:  xor     bx, bx
        mov     fs, bx                  ; base 0, limit stays 4 GB
        mov     gs, bx
        popf
        mov     ax, 1
        ret
vx_unreal ENDP

;---------------------------------------------------------------
; int vx_a20(void)
;   Makes sure the A20 line is on (via HIMEM if loaded, else port
;   92h).  Returns 1 if A20 is on afterwards.
;---------------------------------------------------------------
vx_a20  PROC USES bx si di es
        mov     ax, 4300h
        int     2Fh
        cmp     al, 80h
        jne     va_port92
        mov     ax, 4310h
        int     2Fh
        mov     WORD PTR xmsent, bx
        mov     WORD PTR xmsent+2, es
        mov     ah, 05h                 ; local enable A20
        call    DWORD PTR xmsent
        jmp     SHORT va_test
va_port92:
        in      al, 92h
        test    al, 2
        jnz     va_test
        or      al, 2
        and     al, 0FEh
        out     92h, al
va_test:
        ; compare 0000:0500 with FFFF:0510 (same address if A20 off)
        push    ds
        xor     ax, ax
        mov     ds, ax
        mov     ax, 0FFFFh
        mov     es, ax
        mov     bl, ds:[0500h]
        mov     bh, es:[0510h]
        mov     BYTE PTR ds:[0500h], 0A5h
        mov     BYTE PTR es:[0510h], 05Ah
        mov     al, ds:[0500h]
        mov     ds:[0500h], bl
        mov     es:[0510h], bh
        pop     ds
        cmp     al, 0A5h
        mov     ax, 1
        je      va_done
        xor     ax, ax
va_done:
        ret
vx_a20  ENDP

;---------------------------------------------------------------
; void vx_fill32(unsigned long addr, unsigned long count,
;                unsigned long value)
;   Stores COUNT dwords of VALUE at linear address ADDR.
;---------------------------------------------------------------
vx_fill32 PROC USES bx si di es, alo:WORD, ahi:WORD, clo:WORD, chi:WORD, vlo:WORD, vhi:WORD
        mov     di, ahi
        shl     edi, 16
        mov     di, alo
        mov     cx, chi
        shl     ecx, 16
        mov     cx, clo
        mov     ax, vhi
        shl     eax, 16
        mov     ax, vlo
        test    ecx, ecx
        jz      vf_done
vf_loop:
        mov     DWORD PTR fs:[edi], eax
        add     edi, 4
        dec     ecx
        jnz     vf_loop
vf_done:
        ret
vx_fill32 ENDP

;---------------------------------------------------------------
; void vx_copy(unsigned long dst, void *src, unsigned bytes)
;   Copies BYTES (multiple of 4) from a near buffer to linear DST.
;---------------------------------------------------------------
vx_copy PROC USES bx si di es, dlo:WORD, dhi:WORD, src:WORD, bytes:WORD
        mov     di, dhi
        shl     edi, 16
        mov     di, dlo
        mov     si, src
        mov     cx, bytes
        shr     cx, 2
        jcxz    vc_done
vc_loop:
        mov     eax, [si]
        mov     DWORD PTR fs:[edi], eax
        add     si, 4
        add     edi, 4
        dec     cx
        jnz     vc_loop
vc_done:
        ret
vx_copy ENDP

;---------------------------------------------------------------
; void vx_copyin(void *dst, unsigned long src, unsigned bytes)
;   Copies BYTES (multiple of 4) from linear SRC to a near buffer.
;---------------------------------------------------------------
vx_copyin PROC USES bx si di es, dst:WORD, slo:WORD, shi:WORD, bytes:WORD
        mov     si, shi
        shl     esi, 16
        mov     si, slo
        mov     di, dst
        mov     cx, bytes
        shr     cx, 2
        jcxz    vi_done
vi_loop:
        mov     eax, DWORD PTR fs:[esi]
        mov     [di], eax
        add     esi, 4
        add     di, 4
        dec     cx
        jnz     vi_loop
vi_done:
        ret
vx_copyin ENDP

;---------------------------------------------------------------
; void vx_put16(unsigned long addr, unsigned color)
;---------------------------------------------------------------
vx_put16 PROC USES bx si di es, alo:WORD, ahi:WORD, color:WORD
        mov     di, ahi
        shl     edi, 16
        mov     di, alo
        mov     ax, color
        mov     WORD PTR fs:[edi], ax
        ret
vx_put16 ENDP

;---------------------------------------------------------------
; unsigned char far *vx_font8(void)
;   Returns the BIOS 8x8 character font (INT 10h AX=1130h BH=3).
;---------------------------------------------------------------
vx_font8 PROC USES bx si di es
        push    bp
        mov     ax, 1130h
        mov     bh, 3
        int     10h
        mov     ax, bp
        mov     dx, es
        pop     bp
        ret
vx_font8 ENDP

        END

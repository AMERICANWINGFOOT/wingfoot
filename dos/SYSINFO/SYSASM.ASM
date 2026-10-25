; SYSASM.ASM - low-level helpers for SYSINFO
; Assemble with MASM 6.11:  ML /c /Cx SYSASM.ASM
; Small model, C calling convention.  Preserves BX SI DI ES for
; compatibility with both Microsoft C and Open Watcom __cdecl.

        .MODEL  SMALL, C

        .DATA
fpw     dw      0
xmsent  dd      0

        PUBLIC  cpu_type, cpuid_get, read_tsc, fpu_type
        PUBLIC  loop_tick, xms_info, pci_bios

        .CODE
        .8086

;---------------------------------------------------------------
; int cpu_type(void)
;   0=8086/8088  1=80186/188  2=80286  3=80386  4=80486 (no CPUID)
;   5=CPUID available
;---------------------------------------------------------------
cpu_type PROC USES bx si di es
        pushf
        ; --- 8086/186: flag bits 12-15 cannot be cleared
        pushf
        pop     ax
        and     ax, 0FFFh
        push    ax
        popf
        pushf
        pop     ax
        and     ax, 0F000h
        cmp     ax, 0F000h
        jne     ct_286up
        ; 8086 uses full shift count, 186 masks it to 5 bits
        mov     ax, 1
        mov     cl, 33
        shl     ax, cl
        or      ax, ax
        mov     ax, 0
        jz      ct_done
        mov     ax, 1
        jmp     ct_done
ct_286up:
        ; --- 286: bits 12-14 cannot be set in real mode
        pushf
        pop     ax
        or      ax, 7000h
        push    ax
        popf
        pushf
        pop     ax
        and     ax, 7000h
        jnz     ct_386up
        mov     ax, 2
        jmp     ct_done
ct_386up:
        .386
        ; --- 386: AC flag (bit 18) cannot be toggled
        mov     dx, sp
        and     sp, 0FFFCh          ; align stack for pushfd
        pushfd
        pop     eax
        mov     ecx, eax
        xor     eax, 40000h
        push    eax
        popfd
        pushfd
        pop     eax
        push    ecx
        popfd
        mov     sp, dx
        xor     eax, ecx
        test    eax, 40000h
        jnz     ct_486up
        mov     ax, 3
        jmp     ct_done
ct_486up:
        ; --- 486 without CPUID: ID flag (bit 21) cannot be toggled
        pushfd
        pop     eax
        mov     ecx, eax
        xor     eax, 200000h
        push    eax
        popfd
        pushfd
        pop     eax
        push    ecx
        popfd
        xor     eax, ecx
        test    eax, 200000h
        mov     ax, 4
        jz      ct_done
        mov     ax, 5
ct_done:
        .8086
        popf
        ret
cpu_type ENDP

;---------------------------------------------------------------
; void cpuid_get(unsigned long leaf, unsigned long *regs)
;   regs[0..3] = EAX EBX ECX EDX.  Only call when cpu_type()==5.
;---------------------------------------------------------------
        .386
cpuid_get PROC USES bx si di es, leaflo:WORD, leafhi:WORD, regs:WORD
        push    ebx                 ; keep upper halves intact
        push    esi
        mov     ax, leafhi
        shl     eax, 16
        mov     ax, leaflo
        xor     ecx, ecx
        db      0Fh, 0A2h           ; CPUID
        mov     si, regs
        mov     [si], eax
        mov     [si+4], ebx
        mov     [si+8], ecx
        mov     [si+12], edx
        pop     esi
        pop     ebx
        ret
cpuid_get ENDP

;---------------------------------------------------------------
; void read_tsc(unsigned long *lo, unsigned long *hi)
;   Only call when CPUID reports TSC.
;---------------------------------------------------------------
read_tsc PROC USES bx si di es, plo:WORD, phi:WORD
        db      0Fh, 31h            ; RDTSC
        mov     bx, plo
        mov     [bx], eax
        mov     bx, phi
        mov     [bx], edx
        ret
read_tsc ENDP
        .8086

;---------------------------------------------------------------
; int fpu_type(int cpu)
;   0=none 1=8087 2=80287 3=80387 or later
;---------------------------------------------------------------
        .8087
fpu_type PROC USES bx si di es, cpu:WORD
        fninit
        mov     fpw, 5A5Ah
        fnstsw  fpw
        mov     ax, fpw
        or      al, al
        jnz     ft_none
        fnstcw  fpw
        mov     ax, fpw
        and     ax, 103Fh
        cmp     ax, 003Fh
        jne     ft_none
        cmp     cpu, 2
        jae     ft_infcheck
        mov     ax, 1               ; 8086/186 -> 8087
        ret
ft_infcheck:
        ; 287 treats +inf == -inf (projective), 387 does not
        .287
        fld1
        fldz
        fdivp   st(1), st           ; +inf
        fld     st
        fchs                        ; -inf
        fcompp
        fnstsw  fpw
        mov     ax, fpw
        sahf
        mov     ax, 2
        je      ft_out
        mov     ax, 3
ft_out:
        fninit
        ret
ft_none:
        xor     ax, ax
        ret
fpu_type ENDP
        .8086

;---------------------------------------------------------------
; unsigned long loop_tick(void)
;   Counts simple loop iterations during one 55ms BIOS timer tick.
;   A relative speed index (bigger = faster).
;---------------------------------------------------------------
loop_tick PROC USES bx si di es
        sti
        mov     ax, 40h
        mov     es, ax
        mov     bx, es:[6Ch]
lt_w1:  cmp     bx, es:[6Ch]
        je      lt_w1
        mov     bx, es:[6Ch]
        xor     si, si
        xor     di, di
lt_l1:  add     si, 1
        adc     di, 0
        cmp     bx, es:[6Ch]
        je      lt_l1
        mov     ax, si
        mov     dx, di
        ret
loop_tick ENDP

;---------------------------------------------------------------
; int xms_info(unsigned *ver, unsigned long *largest,
;              unsigned long *total, int use32)
;   Returns 1 if an XMS driver (HIMEM) is present.  Sizes in KB.
;   use32: nonzero lets it try the XMS 3.0 32-bit query (386+).
;---------------------------------------------------------------
xms_info PROC USES bx si di es, pver:WORD, plarge:WORD, ptotal:WORD, use32:WORD
        mov     ax, 4300h
        int     2Fh
        cmp     al, 80h
        je      xi_have
        xor     ax, ax
        ret
xi_have:
        mov     ax, 4310h
        int     2Fh
        mov     word ptr xmsent, bx
        mov     word ptr xmsent+2, es
        mov     ah, 0
        call    dword ptr xmsent
        mov     bx, pver
        mov     [bx], ax
        cmp     use32, 0
        je      xi_16
        cmp     ax, 0300h
        jb      xi_16
        .386
        push    ebx
        push    edx
        mov     ah, 88h
        xor     bl, bl
        call    dword ptr xmsent
        or      bl, bl
        jnz     xi_32fail
        mov     si, plarge
        mov     [si], eax
        mov     si, ptotal
        mov     [si], edx
        pop     edx
        pop     ebx
        mov     ax, 1
        ret
xi_32fail:
        pop     edx
        pop     ebx
        .8086
xi_16:
        mov     ah, 8
        xor     bl, bl
        call    dword ptr xmsent
        mov     si, plarge
        mov     [si], ax
        mov     word ptr [si+2], 0
        mov     si, ptotal
        mov     [si], dx
        mov     word ptr [si+2], 0
        mov     ax, 1
        ret
xms_info ENDP

;---------------------------------------------------------------
; int pci_bios(unsigned *ver, unsigned *lastbus, int is386)
;   Returns 1 if a PCI BIOS is present.
;---------------------------------------------------------------
pci_bios PROC USES bx si di es, pver:WORD, plast:WORD, is386:WORD
        cmp     is386, 0
        je      pb_none             ; PCI BIOS call needs a 386+
        .386
        push    edx
        push    edi
        mov     ax, 0B101h
        xor     edi, edi
        int     1Ah
        jc      pb_fail
        or      ah, ah
        jnz     pb_fail
        cmp     edx, 20494350h      ; 'PCI '
        jne     pb_fail
        mov     si, pver
        mov     [si], bx
        xor     ch, ch
        mov     si, plast
        mov     [si], cx
        pop     edi
        pop     edx
        mov     ax, 1
        ret
pb_fail:
        pop     edi
        pop     edx
        .8086
pb_none:
        xor     ax, ax
        ret
pci_bios ENDP

        END

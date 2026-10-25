; IO32.ASM - 32-bit port I/O and flat memory access for QuickC (small model, C)
;   void outpd32(unsigned port, unsigned lo, unsigned hi);
;   unsigned long inpd32(unsigned port);              result in DX:AX
;   int unreal_on(void);          FS = 4 GB flat (unreal mode); 0 ok, 1 = V86
;   unsigned long mrd32(unsigned long addr);          read  dword at phys addr
;   void mwr32(unsigned long addr, unsigned long v);  write dword at phys addr
; Assemble: ml /c IO32.ASM   (MASM 6.11)   or   wasm -ms IO32.ASM
        .MODEL  SMALL, C
        .386P
        PUBLIC  outpd32, inpd32, unreal_on, mrd32, mwr32

        .DATA
gdt     dw      0, 0, 0, 0                  ; null descriptor
        dw      0FFFFh, 0, 9200h, 00CFh     ; data: base 0, limit 4 GB, G=1
gdtr    dw      15
        dd      0

        .CODE

outpd32 PROC    port:WORD, lo:WORD, hi:WORD
        mov     dx, port
        mov     ax, hi
        shl     eax, 16
        mov     ax, lo
        out     dx, eax
        ret
outpd32 ENDP

inpd32  PROC    port:WORD
        mov     dx, port
        in      eax, dx
        mov     edx, eax
        shr     edx, 16
        ret
inpd32  ENDP

; Enter protected mode just long enough to give FS a 4 GB limit, then
; come back. Real-mode code can then use FS:[EAX] for any address.
unreal_on PROC
        smsw    ax
        test    al, 1
        jnz     uv86                        ; EMM386/Windows: can't do it
        pushf
        cli
        xor     eax, eax
        mov     ax, ds
        shl     eax, 4
        add     eax, OFFSET gdt
        mov     DWORD PTR gdtr+2, eax
        lgdt    FWORD PTR gdtr
        mov     eax, cr0
        or      al, 1
        mov     cr0, eax
        jmp     SHORT upm
upm:    mov     bx, 8
        mov     fs, bx
        and     al, 0FEh
        mov     cr0, eax
        jmp     SHORT urm
urm:    xor     bx, bx
        mov     fs, bx
        popf
        xor     ax, ax
        ret
uv86:   mov     ax, 1
        ret
unreal_on ENDP

mrd32   PROC    alo:WORD, ahi:WORD
        mov     ax, ahi
        shl     eax, 16
        mov     ax, alo
        mov     eax, fs:[eax]
        mov     edx, eax
        shr     edx, 16
        ret
mrd32   ENDP

mwr32   PROC    alo:WORD, ahi:WORD, vlo:WORD, vhi:WORD
        mov     ax, ahi
        shl     eax, 16
        mov     ax, alo
        mov     cx, vhi
        shl     ecx, 16
        mov     cx, vlo
        mov     fs:[eax], ecx
        ret
mwr32   ENDP

        END

SYSINFO 2.0 - DOS system information report
===========================================

Run:      SYSINFO
          Shows the report a page at a time and saves it to SYSINFO.TXT
          in the current directory.

Options:  /N         no pauses (Esc at a pause also turns them off)
          /F:name    save the report under another name
          /F:-       don't save a report file

What it checks: DOS version, BIOS date/vendor, CPU type (8086 to
Pentium and later, CPUID details, clock speed via TSC), math
coprocessor, conventional/extended/XMS/EMS memory, video adapter and
VESA, floppy and hard disks, DOS drive letters and free space, CD-ROM
(MSCDEX), COM/LPT ports and UART type, game port, mouse driver,
Sound Blaster and AdLib, and PCI devices.

Files:    SYSINFO.EXE   ready to run
          SYSINFO.C     C source (QuickC 2.5 / Open Watcom)
          SYSASM.ASM    CPU/FPU/XMS/PCI routines (MASM 6.11)
          SYSASM.OBJ    pre-assembled SYSASM, so MASM isn't required
          MAKE.BAT      rebuild with QuickC 2.5

Note: the sound card and serial port checks briefly write to the
hardware (DSP reset, FIFO test). This is the same thing setup
programs do and is safe on normal PCs.

NEW IN 2.0
  MOTHERBOARD (SMBIOS/DMI) - board maker and model, BIOS version, CPU
    socket, memory slots and sticks, the board's physical ports (is
    there a PS/2 mouse port?) and expansion slots.
  PNP BIOS DEVICES - the devices the BIOS itself reports, with their
    IRQs and I/O ports (a PS/2 mouse shows as PNP0F13 on IRQ 12).
  MOUSE / INPUT - every layer a mouse needs: BIOS equipment flag,
    BIOS PS/2 mouse service (INT 15h C2), the keyboard controller's
    mouse port, IRQ 12, BIOS USB legacy emulation per USB controller,
    INT 33h driver - and a plain-English verdict at the end.
  Options: /NP skips the PnP device list, /NK skips the keyboard
    controller test (use them if SYSINFO ever hangs at that point).
  SMBIOS tables above 1 MB are read in unreal mode (needs no EMM386).
  Build: MAKE.BAT now also links IO32.OBJ (pre-built, from USBXFER).

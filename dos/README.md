# dos/

MS-DOS 6.22 programs for Russell's real-hardware DOS PC: a Pentium 4 1.8 GHz
on a VIA P4M800 Pro / VT8237 board (Phoenix BIOS, 2006) with an ATI Rage XL
PCI card. Written in C for QuickC 2.5 with a few MASM 6.11 helpers, and
test-built with Open Watcom and DOSBox.

The files keep DOS line endings (CRLF) and 8.3 names, so a folder can be
copied straight to the DOS machine. `.gitattributes` stops git converting them.

| Folder | What it is |
|---|---|
| USBXFER | Copy files between a USB stick and DOS. Has its own UHCI/EHCI USB driver (for BIOSes with no USB storage support) and its own FAT16/FAT32 code. `USBXFER` is the command-line tool; `USBXGUI` is a two-panel, mouse-driven file manager built on the same code; `USBDIAG` reports USB controllers and BIOS disks |
| USBMOUSE | USB mouse driver (INT 33h TSR) that talks to the mouse through the UHCI controller, for BIOSes that only emulate a USB keyboard. `MTEST` is a test program |
| VESA | `VESAMODE` lists the card's VESA modes; `VXDEMO` is an 800x600 16-bit plasma and starfield demo using unreal mode and the linear framebuffer |
| SYSINFO | System report: BIOS and motherboard (SMBIOS), CPU and FPU, memory, video and VESA, disks and drive letters, ports, sound, PCI devices. Writes SYSINFO.TXT |
| NET | Start-up files for mTCP networking over the onboard VIA Rhine LAN (the mTCP programs and the FETPKT packet driver are not included) |
| P4BOOT | The machine's AUTOEXEC.BAT and CONFIG.SYS |

## Building

Each folder has a `MAKE.BAT` for QuickC 2.5 (`qcl` on the PATH). The
assembler parts come as pre-built `.OBJ` files, so MASM is not needed.
USBXGUI.C `#include`s USBXFER.C; build it with `MAKEGUI.BAT`. It is close to
the 64 KB code limit of the small model, so if QuickC's code comes out too
big, build it with Open Watcom instead:

    wcl -bt=dos -ms -ox -k10240 usbxgui.c usbdrv.c io32.obj

The `.EXE` files are not kept here (see the top-level `.gitignore`).

## Needs

386 or newer CPU, a PCI BIOS, and plain DOS with no EMM386: the USB code and
VXDEMO use unreal mode. The USB programs need a UHCI (Intel, VIA) or EHCI
controller; OHCI controllers (SiS, ALi, AMD, NVIDIA) are not supported yet.

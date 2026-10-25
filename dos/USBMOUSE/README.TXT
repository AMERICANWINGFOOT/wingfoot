USBMOUSE 1.0 - USB mouse driver for DOS (INT 33h)
=================================================

For PCs whose BIOS only emulates a USB *keyboard* (like the P4's Phoenix
BIOS). USBMOUSE talks to the USB mouse directly through the USB 1.1
(UHCI) controller and gives programs the standard Microsoft mouse
interface (INT 33h), so QuickC, QuickBASIC, games etc. just work.

SETTING UP
  1. The mouse must NOT share a USB controller with the keyboard.
     Each controller drives one PAIR of ports (two stacked ports on the
     back, or a front pair). Put the keyboard in one pair and the mouse
     in a different pair.
  2. Run  USBMOUSE   (AUTOEXEC.BAT does it at boot). It prints which
     controller and port it found the mouse on, e.g.
        USB controller 2 (00:10.1) port 1: Logitech USB Optical Mouse
     If it says "the BIOS is using a keyboard here - leaving it alone"
     for every controller, move the mouse to another pair of ports.

COMMANDS
  USBMOUSE          find the mouse and stay resident
  USBMOUSE /C:2     use USB 1.1 controller 2 (skip the automatic search)
  USBMOUSE /U       unload and give the controller back to the BIOS
  MTEST [secs]      test program: shows x, y and buttons, logs MTEST.TXT
  MTEST 20 G        same test in VGA mode 13h (graphics cursor)

WHAT IT DOES
  - Takes over one USB 1.1 controller (never the keyboard's: it looks at
    the BIOS's own USB schedule first, and checks the device it finds).
  - Puts the mouse in "boot protocol" (every USB mouse supports it) and
    lets the controller poll it in the background every 8 ms.
  - Collects the reports on every timer tick and every INT 33h call.
  - Unplugging and re-plugging the mouse is handled.
  - Cursor: text modes (inverse block) and VGA mode 13h (arrow).
    Other graphics modes: position and buttons work, but no cursor
    is drawn yet (most programs that use mode 12h draw their own).
  - INT 33h functions: 00-0Ch, 0Fh, 10h, 14h, 15h, 1Ah-1Fh, 21h, 24h, 26h
    (reset, show/hide, position, buttons, press/release counts, ranges,
    cursor shapes, motion counters, event handlers, sensitivity, version).
  - Stays in about 34 KB of conventional memory (the USB frame list
    alone needs 4 KB, aligned on a 4 KB boundary).

WITH USBXFER
  USBXFER 2.2 and later know about USBMOUSE and leave its controller
  alone. Use a third pair of ports for the stick (not the keyboard's
  and not the mouse's), or unload USBMOUSE first (USBMOUSE /U).

NOTES
  - Needs a PCI BIOS and a UHCI controller (Intel / VIA chipsets).
  - No EMM386 needed or wanted (the keyboard check uses unreal mode).
  - Wheel and buttons 4/5 are ignored (boot protocol: 3 buttons).

FILES
  USBMOUSE.EXE  the driver          USBMOUSE.C   C source (QuickC 2.5)
  MOUSEASM.ASM  INT 33h/08h entry   MOUSEASM.OBJ pre-built
  IO32.ASM/OBJ  32-bit I/O + unreal mode (shared with USBXFER)
  MTEST.EXE/.C  test program        MAKE.BAT     rebuild with QuickC

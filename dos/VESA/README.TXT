VESA programs
=============

VESAMODE   Lists every VESA mode the video card offers (saves VESAMODE.TXT).

VXDEMO     65,536-color demo drawn straight into the card's linear
           framebuffer using unreal mode, with page flipping.

  VXDEMO [/R:640|800|1024|1280] [/E:1|2] [/T:frames]
    /R:w      screen width (default 800)
    /E:n      start with effect 1 (plasma) or 2 (starfield)
    /T:n      draw n frames, save a screenshot, quit (benchmark)

  Keys:  1 plasma   2 starfield   SPACE new colors
         S save screenshot (VXSHOT00.BMP, VXSHOT01.BMP ...)   ESC quit

  On exit it prints the mode used and the average frames per second.

  Needs: 386 or later, VESA 2.0 card, HIMEM.SYS (or A20 via port 92h),
  and NO EMM386/QEMM - unreal mode only works in true real mode.

Files:  VXDEMO.C   C source (QuickC 2.5 / Open Watcom)
        VXASM.ASM  unreal mode + framebuffer routines (MASM 6.11)
        VXASM.OBJ  pre-assembled, so MASM isn't required
        MAKE.BAT   rebuild both programs with QuickC

USBXFER 2.2 - copy files between a USB stick and DOS 6.22
==========================================================

USBXFER reaches the stick one of two ways:
  1. Through the BIOS (INT 13h), if the BIOS offers USB sticks as a disk.
  2. DIRECTLY through the PC's USB controller, when the BIOS doesn't
     (like the P4's Phoenix BIOS). This is automatic:
       USB 1.1 (UHCI)  about 0.8 MB/s   - the default
       USB 2.0 (EHCI)  much faster      - add /2 (see below)
It has its own FAT16/FAT32 code, because DOS 6.22 can't read FAT32.

USING IT ON THE P4
  - Plug the stick into a USB port that does NOT have the keyboard or
    mouse on the same controller. On the P4 the port that worked is the
    one USBDIAG showed as "00:10.0 port 2".
  - The stick can be plugged in before or after DOS starts.
  - Run  USBXFER DIR  - the first line shows the stick it found, e.g.
        USB stick: SanDisk Cruzer, 15272 MB (controller 00:10.0 port 2)
  - Speed is about 800 KB/s (USB 1.1 speed).
  - USBXFER takes the controller from the BIOS while it runs and gives
    it back when it ends. The keyboard and mouse keep working.

USB 2.0 (/2) - TRY IT CAREFULLY THE FIRST TIME
  The P4's BIOS leaves all USB ports on the USB 1.1 controllers. To use
  USB 2.0, USBXFER /2 flips the chip's "route ports to USB 2.0" switch.
  That briefly unplugs (electrically) the USB keyboard and mouse too;
  USBXFER hands them straight back to USB 1.1, and back again at the end.
  Most BIOSes pick the keyboard up again within a second or two.
  First test:
      USBXFER /2 DIR
  then check the keyboard still types. If it does, /2 is safe on this PC.
  If it doesn't, reboot (Ctrl-Alt-Del may not work - use the reset
  button) and stay with plain USBXFER (USB 1.1).
  Use /Y with /2 for big jobs, so no Yes/No question needs the keyboard.
  USB 2.0 needs plain DOS: no EMM386 (same as VXDEMO).

IF THE STICK ISN'T FOUND - run USBDIAG
  USBDIAG writes USBDIAG.TXT (in the current folder) listing the USB
  controllers, which ports have something plugged in, and every BIOS
  disk with its size and partition table:
      C:\USBXFER> USBDIAG
  then bring C:\USBXFER\USBDIAG.TXT back to Linux.

USBXGUI 1.0 - THE SAME THING WITH A MOUSE AND WINDOWS
=====================================================
  C:\USBXFER> USBXGUI          (same options as USBXFER: /2 /U /C:n /D:81 /Y)

  Two panels: left = a DOS folder, right = the USB stick.
  Uses the mouse through INT 33h, so load USBMOUSE first (AUTOEXEC does).
  Without a mouse driver it still works from the keyboard.

  MOUSE
    Left click            move the bar to a file
    Double click          open a folder (or ".." to go up)
    Right click           select / unselect a file (yellow = selected)
    Arrows in the frame   page up (top right) / page down (bottom line)
    Left panel title      pick another DOS drive
    Bottom bar            the F-key commands
    Buttons in boxes      [ Yes ] [ No ] [ All ] [ Cancel ] etc.

  KEYS
    Arrows PgUp PgDn Home End   move       Tab / Left / Right   panel
    Enter = open folder   Backspace = up   Space or Ins = select
    + all files   - none   * invert
    F1 Help   F2 Rescan (after swapping sticks)   F3 DOS drive
    F4 Stick info   F5 Copy   F6 Select all   F7 New folder
    F8 or Del  Delete   F10 or Esc  Quit

  F5 copies the selected items (or the one under the bar) from the panel
  you're in to the folder shown in the other panel. Folders are copied
  with everything in them (up to 8 levels deep). Overwriting asks first:
  Yes / No / All / Cancel. Esc during a copy stops after the current file.
  F8 deletes - folders with everything in them, so read the box first.

  USBXGUI holds the stick's USB controller until you quit, so keep the
  stick on its own port pair (not the keyboard's, not the mouse's).
  If the stick is pulled out or errors, it says so: plug it back in and
  press F2. After a write error, check the stick on Linux (fsck.vfat).

COMMANDS
  USBXFER DRIVES                       list the BIOS hard disks
  USBXFER INFO                         stick label, size, free space
  USBXFER DIR  [\folder\pattern]       list files (long names shown too)
  USBXFER GET  \folder\pattern [dest]  copy stick -> DOS
  USBXFER PUT  dospattern [\folder]    copy DOS -> stick
  USBXFER DEL  \folder\pattern         delete files on the stick
  USBXFER MD   \folder\newfolder       make a folder on the stick

  Options:  /Y     don't ask before overwriting or deleting
            /2     USB 2.0 speed (see USB 2.0 below)
            /U     go straight to the USB controller (skip the BIOS)
            /C:2   use the 2nd USB 1.1 controller, even if a keyboard
                   or mouse is on it (they stop working while it runs)
            /D:81  use BIOS drive 81h (if auto-detect picks wrong)
            /P:2   use partition 2 on the stick

EXAMPLES
  USBXFER DIR
  USBXFER DIR \PHOTOS\*.JPG
  USBXFER GET \README.TXT              (to the current DOS folder)
  USBXFER GET \PHOTOS C:\TEMP          (every file in \PHOTOS)
  USBXFER GET "\My Notes.txt" C:\      (long names work, use quotes)
  USBXFER MD \FROMDOS
  USBXFER PUT C:\VESA\*.BMP \FROMDOS
  USBXFER /Y PUT C:\SYSINFO\SYSINFO.TXT

NOTES
  - Files copied to DOS get their 8.3 short name (e.g. MYLONG~1.JPG);
    DIR shows the long name next to it.
  - Files copied to the stick are written with 8.3 names (DOS names).
    Linux and Windows read them fine.
  - The program won't write to BIOS drive 80h (your boot disk).
  - Hard disks and CF cards the BIOS lists at 81h and up are skipped
    unless you name them with /D:81 - so a second drive is never
    mistaken for the USB stick.
  - Ctrl-C during a PUT/DEL can leave lost space on the stick; let it
    finish, or run a disk check on Linux (fsck.vfat) afterwards.
  - The stick must be FAT32 or FAT16 (most are FAT32). exFAT and NTFS
    won't work - reformat on Linux:  sudo mkfs.vfat -F 32 /dev/sdX1
  - If DOS itself gave the stick a drive letter (a small FAT16 stick),
    use DOS COPY on that letter instead of mixing it with USBXFER.
  - On Linux, eject the stick before pulling it out.
  - Speed depends on the BIOS USB code; USB 1.1-style emulation can be
    slow (a few hundred KB/s). The speed is shown after big copies.

NEW: USBXGUI 1.0
  - Mouse/keyboard two-panel file manager on top of USBXFER
  - Copies whole folders both ways, deletes folders, makes folders
NEW IN 2.2
  - Leaves alone the USB controller USBMOUSE uses, and any controller
    where the BIOS is reading a keyboard
NEW IN 2.1
  - USB 2.0 (EHCI) driver, /2
  - BIOS drives are only used automatically if they are USB
NEW IN 2.0
  - Direct UHCI USB driver: works with no BIOS USB storage support
NEW IN 1.1
  - Finds sticks the BIOS presents as a floppy (00h/01h)
  - Reads GPT-partitioned sticks (common when formatted on modern Linux)

FILES
  USBXGUI.C   the mouse GUI (it #includes USBXFER.C)   MAKEGUI.BAT builds it
  USBXFER.C   FAT16/FAT32 + commands      USBDRV.C/.H  UHCI + EHCI + USB storage
  IO32.ASM    32-bit I/O + unreal mode (IO32.OBJ is pre-built, no MASM needed)
  USBDIAG.C   diagnostics

BUILD
  MAKE.BAT builds USBXFER.EXE and USBDIAG.EXE with QuickC 2.5

G3 test - Orion StarShoot G3 on Linux (QB64-PE)
================================================

One-time setup on this computer:

  sudo apt install libusb-1.0-0-dev build-essential
  sudo cp 99-orionssg3.rules /lib/udev/rules.d/
  sudo udevadm control --reload-rules
  (then UNPLUG and REPLUG the camera - udevadm trigger alone won't do it)

Check Linux sees it:

  lsusb | grep -i 07ee        -> should show 07ee:0502

Build the library:

  cd ~/Desktop/astro/G3
  sh build_g3.sh

Run: open G3Test.bas in QB64-PE 4.6, cap ON, Ekos/indiserver closed, F5.

Files:
  orion_ssg3.c/.h        Ben Gilsrud's reverse-engineered G3 driver (indi-3rdparty, LGPL)
  ssg3_shim.c            flat wrapper QB64 calls (libssg3.so)
  G3Test.bas             connect + one frame + stats + saved raw/png
  99-orionssg3.rules     udev rule: any 07ee device readable by your user

Notes:
  - Frame is 752x582, 16-bit (Sony ICX419), pixels 8.6 x 8.4 um.
  - Driver's image_download has its size check backwards; the shim always
    passes the exact frame size, so that's handled.
  - Color/mono can't be trusted from USB id - both may show 0502.

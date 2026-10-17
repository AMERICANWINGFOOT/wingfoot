#!/bin/bash
# build.sh - makes the QBGuide camera libraries (ZWO, Orion SSAG, QHY5) (run once, or after editing zwoguide.c)
# ZWO's SDK (libASICamera2.a) is linked right into the .so, so nothing
# has to be installed in /usr/local/lib.
cd "$(dirname "$0")" || exit 1

case "$PWD" in
  *" "*) echo "This folder path has a space in it: $PWD"
         echo "QB64-PE cannot link a .so from a path with spaces. Move the folder."; exit 1;;
esac

if [ ! -f libASICamera2.a ]; then
  echo "libASICamera2.a is missing (it comes from phd2-master/cameras/zwolibs/linux/x64/)"; exit 1
fi

# use the libusb dev link if it is installed, otherwise the runtime library directly
USB=-lusb-1.0
if ! ld -lusb-1.0 -o /dev/null 2>/dev/null && [ -f /usr/lib/x86_64-linux-gnu/libusb-1.0.so.0 ]; then
  USB=/usr/lib/x86_64-linux-gnu/libusb-1.0.so.0
fi

OK=1
gcc -O2 -Wall -fPIC -shared zwoguide.c libASICamera2.a -o libzwoguide.so $USB -lpthread -lstdc++ -lm || OK=0
# Orion StarShoot Autoguider (openssag driver from PHD2; libusb.h is in openssag/)
g++ -O2 -fPIC -shared ssagguide.cpp openssag/openssag.cpp openssag/loader.cpp -Iopenssag -o libssagguide.so $USB -lpthread || OK=0
# original QHY5 guide camera (16c0:296d), ported from PHD2's cam_qhy5.cpp
gcc -O2 -Wall -fPIC -shared qhy5guide.c -Iopenssag -o libqhy5guide.so $USB -lpthread || OK=0
if [ $OK -eq 1 ]; then
  echo "OK: libzwoguide.so, libssagguide.so and libqhy5guide.so built. Now open QBGuide.bas in QB64-PE and press F5."
else
  echo "Build failed. Try: sudo apt install build-essential libusb-1.0-0-dev"
fi

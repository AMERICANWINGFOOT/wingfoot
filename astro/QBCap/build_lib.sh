#!/bin/sh
# Build libqbcap.so for QBCap.
# Run this inside the QBCap folder. That folder must contain:
#   qbcap.c, ASICamera2.h, EFW_filter.h, libASICamera2.so, libEFWFilter.so
#   (headers + .so files from ZWO's Linux SDKs, x64)
# Optional: ssg3_shim.c, orion_ssg3.c, orion_ssg3.h -> libssg3.so (Orion G3)
set -e
cd "$(dirname "$0")"

for f in qbcap.c ASICamera2.h EFW_filter.h libASICamera2.so libEFWFilter.so; do
    [ -f "$f" ] || { echo "missing $f - copy it into this folder first"; exit 1; }
done

# libEFWFilter.so needs libudev but does not say so - link it here (-l:libudev.so.1
# works without the libudev-dev package)
gcc -O2 -Wall -shared -fPIC -o libqbcap.so qbcap.c \
    -L. -lASICamera2 -lEFWFilter -Wl,--no-as-needed -l:libudev.so.1 -Wl,--as-needed \
    -lpthread -lm -ldl -Wl,-rpath,'$ORIGIN'

echo "built libqbcap.so"
ldd libqbcap.so | grep -E "ASICamera2|EFWFilter|udev|usb|not found" || true

# Orion StarShoot G3 (optional): libssg3.so from ssg3_shim.c + orion_ssg3.c.
# If the sources or the libusb headers are missing, QBCap still works -
# the G3 just won't be available.
if [ -f ssg3_shim.c ] && [ -f orion_ssg3.c ] && [ -f orion_ssg3.h ]; then
    if [ -f /usr/include/libusb-1.0/libusb.h ]; then
        if gcc -O2 -Wall -shared -fPIC -o libssg3.so ssg3_shim.c orion_ssg3.c \
               -I. -I/usr/include/libusb-1.0 -lusb-1.0; then
            echo "built libssg3.so (Orion G3)"
        else
            echo "libssg3.so did not build - G3 not available (ZWO cameras unaffected)"
        fi
    else
        echo "skipping libssg3.so: run  sudo apt install libusb-1.0-0-dev  for G3 support"
    fi
fi

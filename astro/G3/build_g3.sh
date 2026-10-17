#!/bin/sh
# Build libssg3.so for the G3 test program.
# Run inside the G3 folder. Needs: sudo apt install libusb-1.0-0-dev build-essential
set -e
cd "$(dirname "$0")"
for f in ssg3_shim.c orion_ssg3.c orion_ssg3.h; do
    [ -f "$f" ] || { echo "missing $f"; exit 1; }
done
[ -f /usr/include/libusb-1.0/libusb.h ] || { echo "libusb headers missing - run: sudo apt install libusb-1.0-0-dev"; exit 1; }
gcc -O2 -Wall -shared -fPIC -o libssg3.so ssg3_shim.c orion_ssg3.c \
    -I. -I/usr/include/libusb-1.0 -lusb-1.0
echo "built libssg3.so"
ldd libssg3.so | grep -E "usb|not found" || true

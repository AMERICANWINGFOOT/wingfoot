#!/bin/bash
# Build the QHY SDK shim (libssaio.so) and the plain C test (ssaio_test).
# Run from the SSAIO folder. Uses the QHY SDK that ships inside INDI's
# libqhy folder, copied in locally, so nothing goes into /usr/local.

cd "$(dirname "$0")" || exit 1

# QHY headers + x86_64 library (the .bin is a renamed .so)
cp ~/Desktop/astro/indi-3rdparty/libqhy/qhyccd.h .
cp ~/Desktop/astro/indi-3rdparty/libqhy/qhyccdcamdef.h .
cp ~/Desktop/astro/indi-3rdparty/libqhy/qhyccderr.h .
cp ~/Desktop/astro/indi-3rdparty/libqhy/qhyccdstruct.h .
cp ~/Desktop/astro/indi-3rdparty/libqhy/x64/libqhyccd.bin libqhyccd.so.20
ln -sf libqhyccd.so.20 libqhyccd.so

# shim: finds libqhyccd.so.20 in its own folder at run time ($ORIGIN)
g++ -O2 -fPIC -shared ssaio.cpp -o libssaio.so -I. -L. -lqhyccd -Wl,-rpath,'$ORIGIN' || exit 1

# plain C test
gcc -O2 ssaio_test.c -o ssaio_test -L. -lssaio -Wl,-rpath,'$ORIGIN' || exit 1

echo "Built libssaio.so and ssaio_test"

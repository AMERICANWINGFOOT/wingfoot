#!/bin/sh
# Build libpmcam.so for PoleMasterQB.
# Run this inside the PoleMasterQB folder:   sh build_pmcam.sh
# (libqhyccd.so is NOT needed to build - it is loaded when you click Connect)
set -e
cd "$(dirname "$0")"
[ -f pmcam.c ] || { echo "missing pmcam.c"; exit 1; }
gcc -O2 -Wall -shared -fPIC -o libpmcam.so pmcam.c -lpthread -lm -ldl
echo "built libpmcam.so"
if [ -f libqhyccd.so ]; then
    echo "libqhyccd.so found in this folder - the real PoleMaster can be used"
else
    echo "NOTE: no libqhyccd.so in this folder yet - copy it here to use the real PoleMaster"
    echo "      (the Simulator works without it)"
fi

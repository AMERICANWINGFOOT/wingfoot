#!/bin/sh
# Build QBCap's built-in plate solver: astrometry.net's solve-field and its
# helper programs, with their libraries, in the "astrometry" folder next to
# QBCap. The folder then works on any Linux Mint 22 / Ubuntu 24.04 (or newer)
# computer without installing astrometry.net - just copy the QBCap folder.
#
# Only needed to make a new copy; the finished astrometry folder is normally
# just copied along with QBCap. Needs internet and the build packages:
#   sudo apt install build-essential git patchelf libcfitsio-dev libgsl-dev \
#        wcslib-dev libjpeg-dev libpng-dev libcairo2-dev libnetpbm11-dev libbz2-dev zlib1g-dev
set -e
cd "$(dirname "$0")"
HERE="$(pwd)"
VER=0.98
SRC=/tmp/astrometry-src-$$

git clone -q --depth 1 --branch $VER https://github.com/dstndstn/astrometry.net "$SRC"
# generic x86-64 code (no -march=native) so it runs on any 64-bit PC
make -C "$SRC" -j"$(nproc)" ARCH_FLAGS="-march=x86-64 -mtune=generic"

rm -rf astrometry
mkdir -p astrometry/bin astrometry/lib
for p in solve-field astrometry-engine image2xy new-wcs fits-guess-scale wcsinfo \
         build-astrometry-index wcs-rd2xy wcs-xy2rd tablist listhead; do
    for d in solver util; do
        [ -f "$SRC/$d/$p" ] && cp "$SRC/$d/$p" astrometry/bin/ && break
    done
done

# every library they use except the core C library (which every system has)
ldd astrometry/bin/* 2>/dev/null | awk '/=> \//{print $3}' | sort -u |
    grep -vE '/(libc|libm|libpthread|libdl|librt|libresolv|ld-linux)[.-]' |
    while read -r l; do cp -L "$l" astrometry/lib/; done

for f in astrometry/bin/*; do strip "$f"; patchelf --set-rpath '$ORIGIN/../lib' "$f"; done
for f in astrometry/lib/*; do strip --strip-unneeded "$f" 2>/dev/null || true; patchelf --set-rpath '$ORIGIN' "$f"; done
cp "$SRC/LICENSE" astrometry/LICENSE 2>/dev/null || true
echo "astrometry.net $VER, built $(date +%Y-%m-%d) on $(. /etc/os-release; echo "$PRETTY_NAME")" > astrometry/VERSION.txt
rm -rf "$SRC"

echo "built $HERE/astrometry ($(du -sh astrometry | cut -f1))"
./astrometry/bin/solve-field 2>&1 | grep -q Astrometry && echo "solve-field runs"

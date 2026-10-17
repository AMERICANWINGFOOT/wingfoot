#!/bin/bash
# build.sh -- builds libvortexvk.so for VortexVK.bas
# Needs:  sudo apt install libvulkan-dev glslang-tools
set -e
cd "$(dirname "$0")"

echo "Compiling shader..."
glslangValidator -V vortex.comp --vn vortex_spv -o vortex_spv.h

echo "Building libvortexvk.so..."
gcc -O2 -fPIC -shared vortexvk.c -o libvortexvk.so -lvulkan

echo "Done. Now compile VortexVK.bas in QB64-PE (this folder, no spaces in the path)."

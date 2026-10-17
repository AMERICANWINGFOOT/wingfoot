#!/bin/sh
# build.sh - builds the Vulkan libfishtank.so for FishTank.bas
# Needs:  sudo apt install libvulkan-dev glslang-tools
set -e
cd "$(dirname "$0")"
glslangValidator -V --target-env vulkan1.0 --vn fishtank_spv -o fishtank_spv.h fishtank.comp
gcc -O2 -Wall -shared -fPIC -o libfishtank.so ftvk.c -lvulkan -lm
echo "Built libfishtank.so (Vulkan)"

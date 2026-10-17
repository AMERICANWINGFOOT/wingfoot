#!/bin/bash
# build_linux.sh - builds OpenNebulosity on Linux Mint / Ubuntu
#   ./build_linux.sh            install packages (asks for sudo once) and build
#   ./build_linux.sh --no-deps  just build
set -e
cd "$(dirname "$0")"

if [ "$1" != "--no-deps" ]; then
  echo "== Installing build packages (needs sudo)"
  sudo apt-get install -y build-essential cmake pkg-config \
       libwxgtk3.2-dev libfreeimage-dev libcfitsio-dev libraw-dev libusb-1.0-0-dev \
    || sudo apt-get install -y build-essential cmake pkg-config \
       libwxgtk3.0-gtk3-dev libfreeimage-dev libcfitsio-dev libraw-dev libusb-1.0-0-dev
fi

case "$PWD" in
  *" "*) echo "Note: this folder path has a space in it; that's fine for CMake but keep it in quotes." ;;
esac

# The ZWO Linux library ships in the original download's Mac_Libraries folder
ZWO_LIB=nebulosity4/linux/zwo/libASICamera2.a
if [ ! -f "$ZWO_LIB" ] && [ -f Mac_Libraries/ASI_linux_mac_SDK_V1.19.1/lib/x64/libASICamera2.a ]; then
  cp Mac_Libraries/ASI_linux_mac_SDK_V1.19.1/lib/x64/libASICamera2.a "$ZWO_LIB"
fi

echo "== Configuring"
mkdir -p build
cd build
cmake .. -DCMAKE_BUILD_TYPE=Release

echo "== Compiling (first build takes a few minutes)"
make -j"$(nproc)"

echo
echo "OK: built $(pwd)/nebulosity"
echo "Run it with:   ./build/nebulosity"
if [ ! -f /etc/udev/rules.d/99-asi.rules ]; then
  echo
  echo "For ZWO cameras, install the USB rule once (then unplug/replug the camera):"
  echo "   sudo cp nebulosity4/linux/zwo/asi.rules /etc/udev/rules.d/99-asi.rules && sudo udevadm control --reload-rules"
fi

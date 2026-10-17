#!/bin/sh
# One-time setup so the QHY PoleMaster works just by plugging it in.
# Run inside the PoleMasterQB folder:   sh install_polemaster.sh
# (asks for your password - it installs fxload, the PoleMaster firmware and a USB rule)
set -e
cd "$(dirname "$0")"
for f in libqhyccd.so qhy/POLEMASTER.HEX qhy/85-polemasterqb.rules; do
    [ -f "$f" ] || { echo "missing $f - it should be in the PoleMasterQB folder"; exit 1; }
done

if command -v fxload >/dev/null 2>&1 || [ -x /sbin/fxload ]; then
    echo "fxload is already installed"
else
    echo "Installing fxload (loads the PoleMaster firmware)..."
    sudo apt-get install -y fxload
fi

echo "Installing the PoleMaster firmware..."
sudo mkdir -p /lib/firmware/qhy
sudo cp qhy/POLEMASTER.HEX /lib/firmware/qhy/

if grep -qs '"0940"' /etc/udev/rules.d/*.rules /lib/udev/rules.d/*.rules /usr/lib/udev/rules.d/*.rules; then
    echo "A USB rule for the PoleMaster is already installed (INDI / QBCap) - keeping it"
else
    echo "Installing the USB rule..."
    sudo cp qhy/85-polemasterqb.rules /etc/udev/rules.d/
fi
sudo udevadm control --reload-rules
sudo udevadm trigger

echo
echo "Done. Unplug the PoleMaster, wait 3 seconds, plug it back in, then run:"
echo "    lsusb | grep 1618"
echo "It should show 1618:0941 (firmware loaded), not 1618:0940."

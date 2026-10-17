#!/bin/sh
# One-time setup so a QHY PoleMaster works in QBCap just by plugging it in.
# Run inside the QBCap folder:   sh install_polemaster.sh
# (asks for your password - it installs fxload, the PoleMaster firmware and a USB rule)
set -e
cd "$(dirname "$0")"
for f in libqhyccd.so qhy/POLEMASTER.HEX qhy/85-qbcap-polemaster.rules; do
    [ -f "$f" ] || { echo "missing $f - copy it into the QBCap folder first"; exit 1; }
done
echo "Installing fxload (loads the PoleMaster firmware)..."
sudo apt-get install -y fxload
echo "Installing the PoleMaster firmware..."
sudo mkdir -p /lib/firmware/qhy
sudo cp qhy/POLEMASTER.HEX /lib/firmware/qhy/
echo "Installing the USB rule..."
sudo cp qhy/85-qbcap-polemaster.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger
echo
echo "Done. Unplug the PoleMaster, wait 3 seconds, plug it back in, then run:"
echo "    lsusb | grep 1618"
echo "It should show a QHY device (1618:0941 or similar, not 0940)."

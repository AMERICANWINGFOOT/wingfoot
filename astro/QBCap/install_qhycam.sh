#!/bin/sh
# One-time setup so the Orion StarShoot All-in-One (QHY5LII-C) works in QBCap
# just by plugging it in. Run inside the QBCap folder:   sh install_qhycam.sh
# (asks for your password - it installs fxload, the camera firmware and a USB rule)
set -e
cd "$(dirname "$0")"
for f in libqhyccd.so qhy/QHY5II.HEX qhy/85-qbcap-ssaio.rules; do
    [ -f "$f" ] || { echo "missing $f - copy it into the QBCap folder first"; exit 1; }
done
echo "Installing fxload (loads the camera firmware)..."
sudo apt-get install -y fxload
echo "Installing the camera firmware..."
sudo mkdir -p /lib/firmware/qhy
sudo cp qhy/QHY5II.HEX /lib/firmware/qhy/
echo "Installing the USB rule..."
# an older hand-made rule for the same camera would load the firmware twice
sudo rm -f /etc/udev/rules.d/85-orion-ssaio.rules
sudo cp qhy/85-qbcap-ssaio.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger
echo
echo "Done. Unplug the All-in-One, wait 3 seconds, plug it back in, then run:"
echo "    lsusb | grep 1618"
echo "It should show 1618:0921 QHY-CCD QHY5-II (not 16c0:29a0)."

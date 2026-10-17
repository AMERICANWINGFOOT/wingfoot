#!/bin/sh
# QBCap - set up a computer after copying the QBCap folder to it.
#
#   sh qbcap_setup.sh          check everything, then fix what it can
#   sh qbcap_setup.sh check    only check, change nothing
#
# Run it inside the QBCap folder. It asks before each change. Only the USB
# rules (and the PoleMaster firmware) need your password; nothing else
# is installed outside the QBCap folder.
#
# Run it again any time something stops working - it only reports what's wrong.

cd "$(dirname "$0")" || exit 1
HERE="$(pwd)"
CHECK_ONLY=0
[ "$1" = "check" ] && CHECK_ONLY=1
PROBLEMS=0

ok()   { echo "  OK    $1"; }
bad()  { echo "  NEED  $1"; PROBLEMS=$((PROBLEMS + 1)); }
note() { echo "        $1"; }
ask()  {
    [ $CHECK_ONLY = 1 ] && return 1
    printf "        %s [y/n] " "$1"
    read -r a
    [ "$a" = "y" ] || [ "$a" = "Y" ]
}

echo "QBCap setup check - folder: $HERE"
echo

# ---- 1. QBCap program and its libraries --------------------------------
echo "1. Program and libraries"
if [ -f QBCap ]; then
    [ -x QBCap ] || chmod +x QBCap 2>/dev/null
    ok "QBCap program"
else
    bad "QBCap program not built yet - compile QBCap.bas in QB64-PE"
    note "(QB64-PE can't compile in a folder whose path has a space in it)"
fi

# ZWO's SDK files are often copied as only the versioned name
# (libEFWFilter.so.1.8.4) - libqbcap.so looks for the plain name.
# A real copy (not a link) works on every kind of drive.
for lib in libASICamera2 libEFWFilter; do
    if [ -f "$lib.so" ]; then
        ok "$lib.so"
    else
        v=$(ls "$lib".so.* 2>/dev/null | sort -V | tail -1)
        if [ -n "$v" ]; then
            bad "$lib.so missing (found $v)"
            if ask "Copy $v to $lib.so?"; then cp "$v" "$lib.so" && ok "$lib.so made from $v" && PROBLEMS=$((PROBLEMS - 1)); fi
        else
            bad "$lib.so missing - copy it from ZWO's Linux SDK (x64) into this folder"
        fi
    fi
done

if [ -f libqbcap.so ]; then
    missing=$(ldd ./libqbcap.so 2>/dev/null | grep "not found" | awk '{print $1}' | tr '\n' ' ')
    if [ -z "$missing" ]; then ok "libqbcap.so finds all its libraries"
    else bad "libqbcap.so can't find: $missing"; fi
else
    bad "libqbcap.so not built - run: sh build_lib.sh"
fi
if [ -f QBCap ]; then
    missing=$(ldd ./QBCap 2>/dev/null | grep "not found" | awk '{print $1}' | tr '\n' ' ')
    [ -z "$missing" ] && ok "QBCap finds all its libraries" || bad "QBCap can't find: $missing"
fi
[ -f libqbgpu.so ] && ok "libqbgpu.so (GPU scoring; without an NVIDIA card QBCap uses the CPU)" \
                   || note "no libqbgpu.so - fine, QBCap scores frames on the CPU"
[ -f libqhyccd.so ] && ok "libqhyccd.so (PoleMaster)" || note "no libqhyccd.so - only needed for the PoleMaster"
echo

# ---- 2. Plate solving ---------------------------------------------------
echo "2. Plate solving"
SOLVER=""
if [ -f astrometry/bin/solve-field ]; then
    chmod +x astrometry/bin/* 2>/dev/null
    if ./astrometry/bin/solve-field --help >/dev/null 2>&1 || ./astrometry/bin/solve-field 2>&1 | grep -q Astrometry; then
        ok "built-in solve-field (astrometry folder)"
        SOLVER=built-in
    else
        bad "built-in solve-field won't run on this computer:"
        ./astrometry/bin/solve-field 2>&1 | head -2 | sed 's/^/        /'
        note "(it needs Linux Mint 22 / Ubuntu 24.04 or newer)"
    fi
fi
if [ -z "$SOLVER" ]; then
    if command -v solve-field >/dev/null 2>&1; then
        ok "solve-field on the system: $(command -v solve-field)"
        SOLVER=system
    else
        bad "no solve-field - copy the astrometry folder into QBCap, or: sudo apt install astrometry.net"
    fi
fi

IDX="index"
if [ -f QBCap_solve.txt ]; then
    l=$(grep -E '^[[:space:]]*index[[:space:]]*=' QBCap_solve.txt | tail -1 | sed 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$l" ] && IDX="$l"
fi
case "$IDX" in /*) ;; *) IDX="$HERE/$IDX" ;; esac
n=$(ls "$IDX"/index-*.fits 2>/dev/null | wc -l)
if [ "$n" -gt 0 ]; then
    ok "$n index files in $IDX"
else
    bad "no index-*.fits files in $IDX"
    note "copy them there, or pick their folder in QBCap: Plate Solve panel > Index folder..."
fi
echo

# ---- 3. USB access for the cameras ---------------------------------------
echo "3. USB rules (cameras and filter wheel without sudo)"
ZWO_RULE=""
for f in /etc/udev/rules.d/*.rules /lib/udev/rules.d/*.rules; do
    grep -qi "03c3" "$f" 2>/dev/null && ZWO_RULE="$f" && break
done
if [ -n "$ZWO_RULE" ]; then
    ok "ZWO USB rule: $ZWO_RULE"
else
    bad "no ZWO USB rule (ASI cameras / EFW need it)"
    if ask "Install the ZWO USB rule (asks for your password)?"; then
        if [ -f 99-qbcap-zwo.rules ]; then
            sudo cp 99-qbcap-zwo.rules /etc/udev/rules.d/
        else
            # ZWO vendor 03c3: open to all users, and raise the USB buffer to
            # 200 MB (ZWO's recommendation for big USB3 frames)
            printf '%s\n%s\n' \
              'SUBSYSTEMS=="usb", ATTRS{idVendor}=="03c3", MODE="0666"' \
              'ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="03c3", RUN+="/bin/sh -c '"'"'echo 200 > /sys/module/usbcore/parameters/usbfs_memory_mb'"'"'"' \
              > /tmp/99-qbcap-zwo.rules
            sudo cp /tmp/99-qbcap-zwo.rules /etc/udev/rules.d/99-qbcap-zwo.rules
            rm -f /tmp/99-qbcap-zwo.rules
        fi
        sudo udevadm control --reload-rules && sudo udevadm trigger
        ok "ZWO USB rule installed - unplug and replug the camera"
        PROBLEMS=$((PROBLEMS - 1))
    fi
fi
if [ -f libqhyccd.so ]; then
    if ls /etc/udev/rules.d/*polemaster* /etc/udev/rules.d/*qhy* >/dev/null 2>&1 && [ -f /lib/firmware/qhy/POLEMASTER.HEX ]; then
        ok "PoleMaster USB rule and firmware"
    else
        bad "PoleMaster USB rule / firmware not installed"
        if [ -f install_polemaster.sh ] && ask "Run install_polemaster.sh now (asks for your password)?"; then
            sh install_polemaster.sh && PROBLEMS=$((PROBLEMS - 1))
        else
            note "run: sh install_polemaster.sh"
        fi
    fi
fi
echo

# ---- 4. Settings that belong to this computer ----------------------------
echo "4. Settings"
[ -f QBCap_site.txt ] && ok "QBCap_site.txt (observing site)" || note "QBCap_site.txt is made on first run - edit it with your site"
[ -f QBCap_mount.txt ] && ok "QBCap_mount.txt: $(grep -E '^[[:space:]]*address' QBCap_mount.txt | sed 's/^[^=]*=[[:space:]]*//')" \
                       || note "QBCap_mount.txt is made on first run"
echo

# ---- 5. Menu launcher -----------------------------------------------------
if [ -f QBCap ]; then
    APPS="$HOME/.local/share/applications"
    if grep -qs "Exec=\"$HERE/QBCap\"" "$APPS/qbcap.desktop"; then
        ok "QBCap is in the applications menu"
    elif ask "Add QBCap to the applications menu (for this folder)?"; then
        mkdir -p "$APPS"
        {
            echo "[Desktop Entry]"
            echo "Type=Application"
            echo "Name=QBCap"
            echo "Comment=ZWO camera capture"
            echo "Exec=\"$HERE/QBCap\""
            echo "Path=$HERE"
            echo "Terminal=false"
            echo "Categories=Science;Astronomy;"
        } > "$APPS/qbcap.desktop"
        ok "added QBCap to the menu"
    fi
fi
echo

if [ $PROBLEMS -le 0 ]; then
    echo "All set - QBCap should run on this computer."
else
    echo "$PROBLEMS thing(s) still need attention (marked NEED above)."
fi

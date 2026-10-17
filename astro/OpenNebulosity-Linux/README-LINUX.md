# OpenNebulosity on Linux

A Linux (GTK) build of Craig Stark's OpenNebulosity 4, made from the original
Windows/macOS source with as few changes as possible. Same C++ code, same
wxWidgets UI; the Windows and macOS builds are not affected (every change is
behind `__LINUX__`).

## Build

```
cd OpenNebulosity-main
./build_linux.sh          # installs the packages below, then builds
./build/nebulosity        # run it
```

Packages it needs (Mint 21/22, Ubuntu 22.04/24.04):
`build-essential cmake pkg-config libwxgtk3.2-dev libfreeimage-dev libcfitsio-dev libraw-dev libusb-1.0-0-dev`

For ZWO cameras, install the USB rule once, then unplug and replug the camera:

```
sudo cp nebulosity4/linux/zwo/asi.rules /etc/udev/rules.d/99-asi.rules
sudo udevadm control --reload-rules
```

## What works (tested Oct 2026)

| Area | Status |
|---|---|
| Main window, menus, display/histogram, zoom | Working |
| Simulator camera: preview, capture, series | Working |
| ZWO ASI cameras | Driver builds and runs (Linux SDK 1.19.1 linked in); reports "No camera found" with nothing plugged in. **Not yet tried on a real camera.** |
| FITS save/open (header: EXPTIME, INSTRUME, DATE-OBS...) | Working, checked with astropy |
| Pre-process (dark subtract) | Working, checked against light-dark arithmetic |
| Align and Combine (translation) | Working: offsets matched the known shifts; 4-frame stack cut noise by 2.0x (ideal sqrt 4) |
| Image menu processing (DDP, curves, levels, etc.) | Opens and runs (DDP tested) |
| Multi-threading | OpenMP (the Windows code path), uses all cores |

## Not on Linux yet

These are compiled as stand-ins (`nebulosity4/linux_camstubs.h`) so the rest
of the program builds unchanged; they aren't listed in the camera menu:

- Cameras with Windows/macOS-only SDKs: Canon DSLR (EDSDK), Atik, SBIG, QHY (old
  and universal), Starlight Xpress, FLI, Moravian, QSI, Apogee, Altair, Meade DSI,
  Fishcamp, Opticstar, Orion StarShoot/SAC, webcams (WDM), ASCOM.
- External filter wheels and focusers (they used ASCOM/HID/IOKit).
- Shoestring DSUSB cable and serial-port code (macOS IOKit).

## Adding a camera driver

1. Get the vendor's Linux SDK (most have one: QHY `libqhyccd`, Atik, SBIG
   `libsbig`, FLI `libfli`, Starlight Xpress via INDI/libusb).
2. In `linux_camstubs.h`, delete that camera's `NEB_LINUX_STUB...` entry.
3. In `camera.h`, include its real header inside the `__LINUX__` block.
4. Add its `.cpp` to `NEB_SOURCES` in `CMakeLists.txt` and link the SDK.
5. Add its name to the Linux camera list in `Nebulosity.cpp` (search for
   "only list cameras that have a working Linux driver").

Good next candidates: ZWO EFW filter wheel (SDK already on Linux), QHY
Universal (`libqhyccd`), and an Orion StarShoot driver from the openssag code
already used in QBGuide.

## What changed, and where

- **`CMakeLists.txt`, `build_linux.sh`** (new): the Linux build.
- **`linux_camstubs.h`** (new): stand-in camera classes.
- **`linux/zwo/`** (new): ZWO Linux SDK header, static library, license, udev rule.
- **`linux/share/nebulosity.png`** (new): window icon (Linux has no resource icons).
- **Platform guards:** macOS code paths that are plain POSIX (path separators,
  canvas layout, FreeImage init, `.fit` naming) now also apply to Linux
  (`#if defined(__APPLE__) || defined(__LINUX__)`). Genuinely macOS-only bits
  (Carbon, IOKit serial, `sysctl`, App Nap, `say`, `\r` script line endings)
  stay macOS-only.
- **`FreeImage.h` includes:** `_WINDOWS_` is undefined after it on Linux,
  because FreeImage defines it and that makes wxWidgets think it's on Windows.
- **`Nebulosity.cpp`:** Linux camera list, PNG icon, Linux chime falls back to
  a beep.
- **`ZWO_ASI.h`:** uses the Linux SDK header that matches the linked library.

Compiler flags are `-fpermissive -w` because the 2000s-era code has many
old-style constructs that modern GCC warns about; nothing was changed in the
processing algorithms themselves.

## License

OpenNebulosity is BSD 3-Clause, Copyright (c) 2021 Craig Stark. The Linux
port changes are offered under the same license. The ZWO SDK in
`nebulosity4/linux/zwo/` is under ZWO's own license (`license.txt` there).

QBGuide - a PHD2-style autoguider for ZWO cameras, the Orion StarShoot
Autoguider and the QHY5, written in QB64-PE
=====================================================================

What it is
----------
A cut-down PHD2 for one job: guide with any ZWO ASI camera, sending the
corrections out of the camera's ST-4 port into the mount's guide port.
No INDI, no wxWidgets, no cmake. The ZWO SDK is linked straight into
libzwoguide.so, so nothing has to be installed system-wide.

The guiding parts are ported from PHD2's own source:
  star centroid ........ star.cpp  Star::Find
  calibration .......... scope.cpp UpdateCalibrationState
                         (West, East back, Dec backlash clear, North, South back)
  calibration step ..... PHD2's calculator: 25 px in about 12 steps, worked out
                         from guide focal length, pixel size, guide rate and Dec
  RA algorithm ......... Hysteresis   (aggression 70%, hysteresis 10%, min move 0.2 px)
  Dec algorithm ........ Resist Switch (aggression 100%, min move 0.2 px)
  camera handling ...... cam_zwo.cpp (snap mode, RAW16, min bandwidth, ASIPulseGuideOn/Off)

Orion StarShoot Autoguider (SSAG)
---------------------------------
Also supported, through openssag - the open-source SSAG driver that ships
with PHD2 (phd2-master/thirdparty/openssag, (c) 2011 Eric J. Holmes,
Orion Telescopes & Binoculars). It loads the camera's firmware by itself
the first time after plugging in (takes a few seconds).
  - Once per computer:  sudo cp ~/Desktop/astro/QBGuide/99-ssag.rules /etc/udev/rules.d/
                        sudo udevadm control --reload   (then replug)
  - It shows in the camera list as "O: Orion StarShoot Autoguider".
  - 1280x1024, 8-bit, 5.2 um pixels, gain 1-15, no binning, ST-4 relays
    timed by the camera itself.
  - Not yet tested on a real SSAG.

QHY5 (original QHY5, USB id 16c0:296d)
---------------------------------------
Ported from PHD2's src/cam_qhy5.cpp. 1280x1024, 8-bit, 5.2 um pixels,
gain 0-100 %, ST-4 pulses timed by the camera (max 2.54 s each; RA then
Dec are sent one after the other, like PHD2).
  - Once per computer:  sudo cp ~/Desktop/astro/QBGuide/99-qhy5.rules /etc/udev/rules.d/
                        sudo udevadm control --reload   (then replug)
  - It shows in the camera list as "Q: QHY5".

Files
-----
  QBGuide.bas     main program
  ZWOCam.bi/.bm   camera helper (ZWO binding + built-in simulator)
  Guide.bi/.bm    star find, auto star, calibration, guide algorithms
  GuideUI.bi/.bm  buttons, settings rows, settings file
  zwoguide.c/.h   thin C shim to the ZWO SDK
  ssagguide.cpp/.h  thin shim to openssag (StarShoot Autoguider)
  openssag/       openssag driver source + firmware + libusb.h (from PHD2)
  libssagguide.so the built SSAG shim
  99-ssag.rules   USB permission rule for the SSAG
  qhy5guide.c/.h  thin shim for the original QHY5 (from PHD2's cam_qhy5.cpp)
  libqhy5guide.so the built QHY5 shim
  99-qhy5.rules   USB permission rule for the QHY5
  libASICamera2.a ZWO SDK (copied from phd2-master/cameras/zwolibs/linux/x64)
  libzwoguide.so  the built shim (prebuilt; rebuild with build.sh)
  build.sh        builds libzwoguide.so
  SimTest.bas     console test: simulator auto star -> calibrate -> guide

Build
-----
1. The folder path must have no spaces (QB64 .so rule).
2. ./build.sh            (only needed if you change zwoguide.c, or the
                          prebuilt .so will not load on this machine)
3. Open QBGuide.bas in QB64-PE and press F5 (or Run > Make executable).
   The program finds libzwoguide.so in this folder.

If the camera list is empty but ASICap sees the camera, the udev rule
for ZWO cameras (asi.rules) is missing on this machine.

Using it
--------
1. Pick the guide camera (or Simulator to practise indoors).
2. Set Guide FL (600 mm for the 120 mm f/5) and Guide rate to match the
   mount's guide speed setting (0.5x is the usual SynScan default).
3. Loop. Adjust Exposure / Gain until stars show (1-2 s is normal).
4. Auto Star, or click a star.
5. Guide. If there is no calibration yet it calibrates first, then
   starts guiding. The search box follows the star every frame during
   calibration. Calibration is saved per camera in QBGuide.ini.
6. Set Declination to roughly where the scope points; RA corrections
   are scaled by cos(Dec), like PHD2 does with a mount connection.
   For a big move in Dec, or after a meridian flip, press Clear Cal
   and calibrate again.

Pulse N/S/E/W sends a 1000 ms test pulse - use it with Loop running to
check the ST-4 cable before calibrating (the star should move).

Take Darks: cap the scope first. Takes 16 frames at the current
exposure and gain, then maps the hot pixels. The Dark button cycles:
  Dark: hot px    - hot pixels replaced by their neighbours (default).
                    Adds no noise; works at any exposure or gain.
  Dark: subtract  - full dark subtraction; only applied when exposure,
                    gain and binning match the darks.
  Dark: off
"Dark: mismatch" means the darks don't fit the current settings and
are NOT being applied (retake them, or use hot px).

Each guiding run writes QBGuide_YYYYMMDD_HHMMSS.csv (frame, time,
offsets, RA/Dec error in pixels, pulse direction and length, SNR, HFD).

Keys: L loop, S stop, A auto star, C calibrate, G guide, Esc quit.

Things PHD2 does that this does not (yet)
-----------------------------------------
dithering / server API for imaging apps, multi-star guiding, the
Gaussian Process / PEC algorithm, Guiding Assistant, automatic
meridian-flip handling (needs a mount connection), and mount guiding
over SynScan WiFi (ST-4 only for now).

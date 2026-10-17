# Astro work - handoff notes (Oct 14, 2026)

Two parts: **Part 1 is for Russell**, **Part 2 is for Claude** (paste or point
the next chat at this file: `astro/NOTES.md` in the wingfoot repo).

---------------------------------------------------------------------------

## Part 1 - For Russell

### Where things stand

| Program | Folder | Status |
|---|---|---|
| QBGuide | ~/Desktop/astro/QBGuide | Works with the QHY5 indoors and with the Simulator. **Not yet tested under real stars.** |
| QBCap | ~/Desktop/astro/QBCap | Filter-wheel slot fix, Esc-in-edit fix, plate-solve settle wait, Quit button with safe shutdown - all in. |
| SER tools | ~/Desktop/astro/SER stacker (repo: tools/SERTools) | SERTool + SERReport fixed for Linux; SERPlay, SERCenter compile as-is. |

### Cameras and their jobs

- **QHY5** (16c0:296d) - the guide camera, in QBGuide. Works. "Now it has a new life."
- **Orion G3 mono** - deep-sky imaging (Bubble Nebula). Big pixels (about 8.6 um).
  Goes into QBCap later. Existing start: the G3 QB64 app idea + INDI driver built.
- **ToupCam TP61400A** - Moon camera. Tiny pixels (about 1.4 um), about 0.3"/px on the 8".
  Works on Linux through libtoupcam.so (TriggerSync, no shim).
- **ZWO ASI178 / 174 / 1600** - QBCap and QBGuide both support them.
- **Orion SSAG** - supported in QBGuide, never tried on a real one.

### Plan, in order

1. **First real night with QBGuide** - QHY5 on the 120 mm guide scope (600 mm).
   Loop -> Pulse N/S/E/W (star should move) -> Auto Star -> Guide (calibrates first).
   Watch the RMS on the bullseye. Compare with PHD2 if there is time.
2. **Moon guiding** - click a crater, track it by patch matching. ToupCam on the 8",
   pulses out through the QHY5's ST-4 port.
3. **G3 into QBCap** - cooled mono imaging, 10 min max exposure (amp glow),
   matched darks at the same exposure/gain/temperature.
4. **Bubble Nebula (NGC 7635)** - G3 mono + H-alpha on the 8" (1000 mm):
   about 1.8"/px, field about 22' x 17', bubble about 100 px across.
   3-5 min subs, a few hours total, guided by QBGuide.
5. Later: dithering in QBGuide, make QBGuide public, post on the QB64 forum.
6. **Mount over USB, as a menu option** - the USB code is already in QBCap
   (`qbcap.c`) and PMQBauto (`pmmount.c`); today you switch by editing
   `QBCap_mount.txt` / `PoleMasterQB.ini` to `/dev/ttyUSB0`. Add a WiFi/USB
   choice on the mount panel that finds the port itself (ttyUSB0 / ttyACM0),
   remembers it, and warns about the dialout group. Hand controller goes in
   PC Direct Mode. Also the backup if the SynScan WiFi ever quits.
   Test once on a cloudy night.
7. **Mount hub app** - one QB64 app that owns the USB port (only one program
   can have it open). Hand-paddle buttons, GoTo, park/home, tracking rates,
   no-go zone for the tripod legs, low-altitude limit. Works on USB or WiFi.
8. **"CAN bus" between the apps** - Linux SocketCAN virtual bus (`vcan0`) with a
   small C shim (libqbcan.so). Every app hears every frame; low ID = high
   priority: 0x001 STOP/ABORT, 0x010 guide pulse, 0x100 GoTo, 0x200+ status.
   CAN FD gives 64 bytes per frame. Gives the QBGuide-QBCap link for autopilot
   (guiding pauses during GoTo, dither/settle). Fallback: UDP broadcast on
   127.0.0.1 with the same IDs. Needs a boot-time service to bring up vcan0.
9. **Pulse guiding through the mount (no ST-4 cable)** - QBGuide option
   "Guide via: Camera ST-4 / Mount". RA: run at e.g. 1.5x or 0.5x sidereal for
   the pulse length, then back to sidereal. Dec: guide rate for the pulse, then
   stop. Sent as 0x010 frames to the mount hub. Best over USB (WiFi timing
   jitter). Check the Atlas Pro firmware takes rate changes while moving.

### THE BIG ONE - QBCap sequencer (next QBCap job)

A list of steps QBCap runs by itself all night, e.g.
`M57 | Red | 120 s | x20`, then `Green`, then `Blue`, then darks, then park.

- Each row: target name, filter (EFW slot), exposure, gain, count, binning.
- Optional per target: GoTo + plate-solve centre before starting.
- Files named automatically: `M57_Red_120s_0001.fits`, FILTER in the FITS header,
  each filter in its own folder (this was already on the to-do list).
- Waits for guiding to settle before each frame; dither between frames later
  (QBCap and QBGuide need a simple link for that - a small shared file is enough).
- Cooler on at the start, temperature check; at the end run ShutDown
  (cooler off, park/stop mount, "Safe to unplug").
- Save/load sequences as a text file; Pause / Skip / Abort buttons; a log of
  what was taken.
- Uses parts QBCap already has: EFW, FITS saving, GoTo, plate solve, cooler,
  ShutDown.

### Remote interface - so Claude can run QBCap and hunt bugs itself

Works with the file bridge Claude already has (it can put files into the
QBCap folder and read files back - no network, no extra software):

- **QBCap_cmd.txt** - Claude drops commands in, one per line, e.g.
  `LOOP`, `EXP 2000`, `GAIN 100`, `FILTER 3`, `SNAP`, `SOLVE`, `GOTO M57`,
  `SEQ START myplan.txt`, `SCREENSHOT`, `QUIT`.
  QBCap checks the file every loop, runs the commands, then empties it.
- **QBCap_status.txt** - QBCap rewrites this every second or two: mode,
  camera, temperature, exposure, filter, mount RA/Dec, last solve, last error.
- **QBCap_log.txt** - every action and error with a timestamp (the log that
  was "gold" before).
- **SCREENSHOT** - QBCap saves its whole window as a PNG (_SaveImage) so
  Claude can see exactly what Russell sees.
- Safety: mount moves only if a "Remote mount: on" switch is set in QBCap;
  Russell can always take over with the mouse; QUIT runs the normal ShutDown.
- Same idea can go into QBGuide later (status + CSV already exist).
- Build this together with the sequencer - the sequencer's steps and the
  remote commands can share the same command code.

### Darks finding (Oct 15)
- Darks work on the ASI178MM indoors (flat noise, cap on).
- On the sky (Oct 14) guiding with darks on was worse - cause not found yet.
  Look at the QBGuide_*.csv logs (SNR/HFD with darks on vs off).
- Known bug for the QHY5 only: offset 100 after dark subtraction is too small
  for 8-bit data (steps of 256) - raise it to about 2000 (QBGuide.bas line ~410).

### Things to remember (lessons learned)

- **After I send a new .bas: close the file in the QB64 IDE without saving, reopen it,
  then F5.** Otherwise the IDE runs (or saves back) the old copy.
- `build.sh` lost its run permission when copied: use `bash build.sh`.
- Commands with files: always use the full path, e.g.
  `sudo cp ~/Desktop/astro/QBGuide/99-qhy5.rules /etc/udev/rules.d/`
  then `sudo udevadm control --reload` and replug the camera.
- QHY5 with cap on = noise; cap off indoors = bright scene. QBGuide shows a
  red SATURATED banner when the frame is blown out - lower exposure/gain.
- QBGuide: Esc or Quit asks "Sure" first. Calibration older than 12 hours asks
  for a second Guide press. Darks must match exposure and gain ("Dark: mismatch").
- Before anything goes public: remove the mount WiFi password and the site file.
  Use a public site (Kitt Peak, AZ) as the default location.

---------------------------------------------------------------------------

## Part 2 - For Claude (technical handoff)

### Russell's setup
- Linux (Mint/Arch-family box), QB64-PE 4.6 in the IDE. I test-compile with 4.7.
- Mount: Orion Atlas Pro AZ/EQ-G (SynScan WiFi in QBCap; ST-4 in QBGuide).
- Scopes: 8" 1000 mm, 10" 1200 mm, 120 mm f/5 guide scope (600 mm).
- Delivery to his machine: device_commit_files from a **fresh staging folder each
  time**, then check sizes with device_list_dir (re-using the same staging path
  once delivered an old file).
- Give full paths in every shell command.
- Repo: AMERICANWINGFOOT/wingfoot (public), clone at /home/claude/wingfoot.
  .gitignore keeps out .so, .a, logs, csv, ini data.

### QBGuide layout (astro/QBGuide)
- `zwoguide.c/.h` (zg_*), `ssagguide.cpp/.h` + `openssag/` (sg_*), `qhy5guide.c/.h` (q5_*):
  same flat API - open, set gain, start_exposure(ms), exp_status (0 idle,
  1 working, 2 done, 3 failed), read_frame(uintptr_t), guide(raDir, raMs, decDir, decMs)
  on a pthread, guide_busy, guide_stop. Directions 0 N, 1 S, 2 E, 3 W, -1 none.
- `build.sh` builds all three .so. libASICamera2.a comes from
  phd2-master/cameras/zwolibs/linux/x64 (not in repo).
- `ZWOCam.bi/.bm`: Declare Library "./zwoguide" etc.; CAM_SIM=-1, CAM_SSAG=1000,
  CAM_QHY5=1001; CamOpen/CamStart/CamStatus/CamRead/CamPulse; built-in simulator
  (PE, seeing, Dec backlash, hot pixels).
- `Guide.bi/.bm`: StarFind (PHD2 Star::Find), StarAutoFind, CamToMount,
  CalBegin/CalStep, AlgoHysteresis (RA), AlgoResistSwitch (Dec), CalcCalStepMs.
- `GuideUI.bi/.bm`: UIPoll (presses caught inside event loop), Btn, SpinRow,
  Fmt$ (no exponents), Ini* helpers.
- `QBGuide.bas`: camera picker, 800x600 view, bullseye (DrawTarget) + graph strip,
  bright-view + saturation banner, per-camera calibration in QBGuide.ini
  (rates in px/s, when_hours), CSV log per run, operator-trap guards.
- `SimTest.bas`: console sim test. Last result: calibration within about 1.5 deg / 2 %,
  RMS about 0.6". Monkey test (xdotool, 3000 random actions): 0 crashes.
- QHY5 shim port of PHD2 cam_qhy5.cpp: 1558x1050 read, crop to 1280x1024 at
  offset 20; guide cmd 0x10, max 2540 ms per pulse; RA then Dec.

### QB64-PE gotchas hit in this work
- `_Offset` <-> `uintptr_t` in C headers (not void*).
- Names that clash: `inp` (keyword), a variable `px` vs Const PX - rename.
- Never write `$Include` inside a comment.
- `Declare Library "./name"` finds name.h + libname.so in the source folder.
- ToupCam handle must be `_Offset`, not Long.

### QBCap (astro/QBCap)
- Remembers last wheel in QBCap_lastwheel.txt ("EFW_5|5") so a dropped USB wheel
  doesn't fall back to 8 slots.
- GoTo check solve waits `1 + 2*exp` seconds after the slew (gotoState 4).
- ShutDown order: cancel solve, stop record, stop guider, close mount,
  cooler off, close camera / EFW / PoleMaster, log "Safe to unplug".
- Still open (from memory notes): file naming with target+filter+exposure,
  FILTER in FITS header, slew limits, RGB combine, manual plate-solve alignment.

### Next work items for Claude
1. Help read the first real-night QBGuide CSV log (calibration angles, RMS, pulse sizes).
2. Moon mode: patch-match (normalized cross-correlation) on a clicked feature,
   feed offsets into the same GuideStep; ToupCam frame source via libtoupcam.so.
3. G3: check sensor size from the camera itself (orion_ssg3 get_image_width/height) -
   notes disagree (752x582 vs 1280x1024). Add as a QBCap camera; 10 min exposure cap.
4. Dithering for QBGuide (needed for amp glow / hot pixels on long G3 runs).
5. Optional: QBGuide.sh launcher, QHY5 as polar camera in PMQBauto,
   public QBGuide repo (scrub first).
6. Mount stack (Plan items 6-9): reuse the serial/UDP code already in
   `qbcap.c` and `pmmount.c` as one shared library; mount hub owns the port;
   SocketCAN `vcan0` bus via libqbcan.so (non-blocking can_open/can_send/
   can_recv, RA/Dec packed as two Longs with MKL$/CVL); then mount pulse guiding
   in QBGuide. Untested sketch of the shim was written Oct 17 (not in repo).

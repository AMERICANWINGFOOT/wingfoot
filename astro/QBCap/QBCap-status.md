# QBCap — Linux capture program for ZWO cameras (status, 2026-10-07 11:25, v0.11 + GoTo, SynScan list, Moon, 10-min exposures, autoguiding)

QB64-PE front end (QBCap.bas) + C capture library (libqbcap.so) + optional CUDA library (libqbgpu.so) + optional QHY library (libqhyccd.so, for the PoleMaster).
Lives in ~/Desktop/QBCap on the Rampage box (user wingfooot, Linux Mint).
Backup copies of the current sources are in this Project under claude/src/ (QBCap.bas, qbcap.c, qbgpu.cu, build_lib.sh, build_gpu.sh, 99-qbcap-zwo.rules, install_polemaster.sh, 85-qbcap-polemaster.rules, mounttest.c, mountjog.c).

## Resume here
- **Autoguiding (09:10)**: guide window = second copy `./QBCap --guide` (or Tools > Guider / Guider panel "Open guide window" in the main copy). Corrections go out of the guide camera's ST-4 port (Russell uses an ST-4 cable). Not yet tried on his gear. Needs build_lib.sh + recompile. Open question: which camera he guides with (picker only knows ASI174/178/1600).
- **Exposure up to 10 min (08:30)**: camera exposure control is now log-scale 1 ms - 600 s (EXP_MAX_MS) with -/+ buttons stepping through usual values (EXP_STEPS); value shown as ms / s / min. Capture thread waits in 0.5 s steps (ASIGetVideoData timeout = not ready yet) so Stop is instant during long exposures. PoleMaster exposure still 100-5000 ms. Confirmed working on Russell's machine (08:39).
- **GoTo + sync + learn directions + polar RA turn (2026-10-07 ~06:05)** — delivered (qbcap.c 171,438 B, QBCap.bas 123,631 B). Russell must `sh build_lib.sh` + recompile. Needs clear sky to test for real.
- **v0.11 (2026-10-07 ~05:45): mount control built into QBCap** — sources delivered (qbcap.c 167,962 B, QBCap.bas 101,595 B); Russell must run `sh build_lib.sh` and recompile QBCap.bas in QB64-PE. **Confirmed working on his machine and mount (05:45).** Mount is in **EQ mode**.
- **Next: Russell's real-sky beta test.** Everything below is built and on his machine. Afterwards, read ~/Desktop/QBCap/QBCap.log, the solve/ folder logs and any screenshots he sends, and fix what turns up.
- **Mount jog tool delivered** (mountjog, see below) — first real test: slow speed, check directions, cable clearance.
- **After that: mount control in QBCap** (see "Mount" below) — connection to his mount already proven with mounttest.
- His real PoleMaster works on his machine (install script done, connects as "POLEMASTER", 1280x960, live view OK). Polar Align now uses only the PoleMaster (camera choice removed).
- QBCap_site.txt on his machine holds his own site (default = no). It is only used for the alt/az split. Do not copy or record his location anywhere else; never ask for it again.
- Beta-test plan given to him: PoleMaster polar align (1–2 s, gain 30–60) → plate solve a live C8 frame with scale hint → live stack with Align on stars → recording / filter wheel / darks outdoors. If anything goes wrong: keep QBCap.log, the solve folder, a screenshot, and note the time.
- Not yet tried on real sky: polar alignment, plate solving through the C8, live stacking with star alignment.

## Mount jog (mountjog, delivered 2026-10-07)
- ~/Desktop/QBCap/mount/mountjog (source mountjog.c, built by build_mount.sh; backup claude/src/mountjog.c). Run `./mountjog` on the mount's WiFi, or `./mountjog /dev/ttyUSB0 [9600]` for USB.
- Keys: arrows move (left/right = RA axis 1, up/down = Dec axis 2), 1–6 speed (1×, 8×, 32× sidereal, 0.5, 1, 2°/s), SPACE stop, t = RA sidereal tracking, p = positions, q = quit.
- Safety: each move auto-stops after 10 s (same key again adds 10 s); 2°/s max; Ctrl-C / closing the terminal stops both axes.
- Sends :F1/:F2 (init) on start. Move = :K, wait until :f says stopped, :G (mode 1 slow / 3 high-speed above 128× sidereal; direction 0/1), :I period (T1 = 53694·360/speed/9216000, ×16 high-speed ratio), :J.
- v2 (after the mount hit something on Russell's first real run, 2026-10-07): stall watchdog (every 0.5 s after the first 2 s; < 25% of expected motion → stop both axes, beep), 60° travel fence from the start-up position per axis, speed report after each stop (deg moved, seconds, average deg/s). Real mount reports high-speed ratio 32 (:g). Cannot detect a slipping clutch (motor counts keep going).
- Tested here against a simulated mount (1°/s for 2.5 s → 2.48°, sidereal 10 s → 0.042°, auto-stop OK). Not yet run on the real mount; which way + and − go on each axis is unknown until then.

## Real-mount findings (mountjog on Russell's mount, 2026-10-07 early morning)
- First try at 2 deg/s the mount ran into something (no damage reported); that run's numbers were discarded. Led to mountjog v2 safety (stall stop, 60 deg fence, speed report).
- First copy of v2 did not reach his machine (old 10,700-byte source stayed). Check file size / `grep -c STALLED mountjog.c` after sending; resent, now 13,406 bytes, rebuilt with build_mount.sh.
- :g high-speed ratio = 32 (not 16). Speeds confirmed: 32x sidereal measured 0.131 deg/s (RA) and 0.125 deg/s (Dec) incl. ramps (target 0.134); 2 deg/s runs moved ~24 deg / ~20 deg in ~10-12 s.
- Stall watchdog did not false-trigger at 32x. Still to check: speeds 4 (0.5 deg/s) and 6 (2 deg/s) for false trips during ramp-up.
- Positions reset to 0 at mount power-up (counts from wherever it is).
- **Freedom Find (axis encoders) is active**: pushing the scope by hand with clutches loose changed :j positions (RA 26.64 -> -3.57, Dec 22.00 -> 2.38) with motors stopped. So :j reports the axis encoders -> stall stop should also catch a slipping clutch (not yet seen happen). After hand moves, restart mountjog so the 60 deg fence re-centres.
- Directions: right arrow (axis 1 +) tips the scope WEST. Up arrow (axis 2 +) also looked "left/west" at that pointing - Dec direction depends on pointing / side of pier, so not a fixed label.
- Plan: QBCap learns axis directions itself (solve, nudge one axis, solve again; sign of RA/Dec change), which also handles meridian flips.
- Open question to Russell: mount set up in EQ mode or AZ mode?
- 05:11 run: RA 2 deg/s fine (31.8 deg in 18 s). Dec at 2 deg/s tripped the stall stop 4 times (position moved ~0.04 deg per check, - direction 0.25 deg in 0.5 s) although Russell says Dec "looked smooth". Unresolved: is :j for Dec lagging at high speed, or is Dec slipping? mountjog v3 logs every 0.5 s check (pos, moved, expected, :f status) to mountjog.log, needs 2 bad checks in a row to stop, and 'w' toggles the stall stop.
- 05:16-05:19 log (mountjog.log) findings: (a) BUG: 0.5 deg/s used slow mode with period 4.2 clamped to 6 -> really 0.35 deg/s; in one run Dec only jittered back and forth at that setting (pos 0.40/0.45/0.42/0.38/0.51/0.69...), in the next it ran steadily at 0.35. Fixed in v4: slow mode only when its period >= 10, else high-speed mode (0.5 deg/s -> period 134 high-speed). (b) At 2 deg/s Dec speeds up over ~1.5 s, then holds exactly 2 deg/s; single readings can jump (1.99 then 0.43 in the next window) - timing jitter, covered by the 2-bad-checks rule. :f status 111 = slow mode running, 511 = high-speed running.
- DELIVERY GOTCHA: re-committing from the same staged path (/mnt/user-data/outputs/mount/...) delivered the OLD file content twice. Stage each new version under a fresh folder (e.g. outputs/mountv3/) and verify sizes with device_list_dir.

## Mount control in QBCap (v0.11, step 10)
- qbcap.c step 10: qc_mount_open(addr) / close / is_open / move(axis 1 RA|2 Dec, speedIdx 1-6, dir) / track(on) / stop / status(raDeg, decDeg, raState, decState, tracking) / message (seq no.) / info ("AZ-EQ6 firmware 2.11").
- One background thread does all mount I/O. Jog must be re-sent at least every 0.6 s (GUI sends it every frame while a button is held; release sent once) - a frozen GUI stops the mount. RA +1 = West = tracking direction.
- Thread: positions every 0.25 s; stall stop (moves >= 0.05 deg/s, after 2 s, 2 checks in a row < 25% of expected) stops both axes + tracking off, and a held button is ignored until released; lost link (2 failed position polls, ~1.2 s) -> stop wanted + tracking off + message; "Mount answering again" when it comes back. Speeds: same table and high/slow-mode rule as mountjog v4.
- QBCap.bas: group 13 "Mount" + toolbar/Tools-menu "Mount" (opens the panel, collapses others, connects). Address from QBCap_mount.txt (created with 192.168.4.1; /dev/ttyUSB0 or /dev/ttyUSB0,9600 for USB). Panel: info, axis degrees, RA/Dec state, Speed cycler (default 32x), hold-to-move pad Dec+ / East / STOP / West / Dec-, Tracking checkbox, red word-wrapped mount message, Disconnect. Status bar shows "MOUNT: ..." messages. Mount closed (stopped) on exit.
- Tested here vs fake UDP mount (Xvfb): connect, hold West at 2 deg/s, release -> :K immediately, tracking, Dec stall at a simulated wall, lost link + recovery.

## Pointing + GoTo (in v0.11 sources, after the jog panel)
- C: qc_mount_goto_axes(dRA, dDec) relative axis GoTo run by the mount thread (profile >5 deg 2 deg/s, >2 1, >0.6 0.5, >0.15 32x, >0.01 8x, done within 0.01 deg; 240 s limit; buttons/STOP/stall/lost cancel; tracking pauses during GoTo and resumes after). qc_mount_lst(lon) = LST deg from the PC clock (utc_jd + gmst_rad).
- Test-only hook: compile with -DQC_TEST_SOLVE and env QC_TEST_SOLVE=<file> -> qc_solve_start returns "RA Dec" from that file immediately (not in the shipped build).
- BAS pointing model (2026-10-14, replaces the old learned kRA/kDec + "Learn directions"): German-equatorial geometry from HOME (axes count from power-up = counterweight down, scope at pole). Dec axis + side: HA = RAax + raIdx + 90, Dec = 90 - (DecAx + decIdx); - side: HA = RAax + raIdx - 90, Dec = 90 + (DecAx + decIdx). The mirror explains why "Dec up" looked different on Oct 12 (- side) vs Oct 13 (+ side). Every camera solve with the mount connected measures raIdx/decIdx (the side giving the smaller error); above Dec +88 it keeps HOME as is (RA error unmeasurable there). GoTo (AimAxes) picks the counterweight-down solution (RA axis nearest HOME). Russell's HOME error from the 2026-10-13 log ~ RA -5, Dec +4.4..5.7 deg.
- Alignment = Russell's routine: Solve & Sync at HOME, GoTo, solve/correct (the "Centre with a plate solve after" passes, up to 3). Pointing panel button is now "Solve & Sync" (Learn removed). GoTo/centre uses gotoTgt (fixes the 2026-10-12 "M39 1233 arcmin off" when the picker changed during a slew).
- GoTo list: 110 Messier (OpenNGC; M102 = NGC 5866) + 52 bright stars (PyEphem, J2000) as DATA at the end of the main module (CatalogData). Picker << < name > >> (+ mouse wheel), "List only objects above 15 deg", altitude shown, "Centre with a plate solve after".
- GoTo: refuses below 10 deg alt, refuses RA turns > 150 deg (meridian / pier side - no flip logic), shows the axis amounts and needs Confirm; turns tracking on; aims ahead by the slew time; after the slew solves and corrects up to 3 times until < 2 arcmin.
- Polar align: after Step 1 (mount connected) buttons "Turn RA 75 E/W"; when the turn finishes Step 2 starts by itself.
- Tested here with a fake mount whose hidden geometry (Dec axis reversed, offsets) writes the true pointing + the test solve hook: directions learned correctly (Dec + = down for that sim), GoTo M42 centred 1.1' first try, M31 (61 deg RA turn) centred, tracking holds.
- **Moon** (added 06:30): list entry 1 "Moon", position from qc_moon_radec(lat, lon) — Meeus ch.47 main terms, topocentric (spherical Earth), precessed to J2000; matches astropy topocentric within ~30". Refreshed every mount poll. GoTo Moon skips the plate-solve centring and switches tracking to the lunar rate (qc_mount_track_rate(1) = 14.685"/s); any other GoTo sets sidereal. Tracking checkbox label shows the rate. Quick-jump buttons Moon / Messier / Stars above the picker. (PyEphem's topocentric .ra with epoch J2000 disagreed by ~0.35 deg - don't use it as a reference; astropy agrees with ours.)
- **SynScan object list** (06:40): Russell supplied the SynScan app's skyobj.sqlite (tables tblDso 10,759 with idM/idNgc/idIc/idC + J2000 rad + vmag + constId; tblDsoName; tblNamedStar 306 with SAO J2000 rad + proper motion RA s/yr, Dec "/yr; tblDoubleStar 55; tblConstellation 88). tools/make_objects.py turns it into QBCap_objects.txt (name|description|list|RA h|Dec deg|mag; 11,548 objects: Messier 110, Caldwell 109 (C14 a/b), stars by brightness (pm carried to 2026.8), doubles, NGC 7203, IC 3764). QBCap loads it at start (falls back to the built-in DATA list if missing); NCATMAX 12000. Panel: List cycler (Moon/Messier/Caldwell/Stars/Double stars/NGC/IC jumps to that list), Find... text box (M31, ngc7000, C14, Vega, part of a common name e.g. whirlpool; a bare number = that number in the list on show).
- Not handled yet: meridian flip, pole crossing, refraction, absolute pier side, planets.

## Autoguiding (step 11)
- C (qbcap.c, end): guide_frame() runs on the capture thread of the copy that has the guide camera (gd_on). Star = brightest unsaturated, non-hot-pixel peak (or near a clicked point), 3-pass centroid in a 25x25 box with edge-median background; lost after 4 bad frames. Pulses: ASIPulseGuideOn + a 2 ms pulse thread that switches them off; opposite direction switched off first. One correction, then skip the frames exposed during the pulse (video mode streams continuously).
- Calibration: West steps (calMs, default 750) until 20 px or 30 steps, East back (measured), Dec backlash clear (North up to 10 steps / 3 px), North steps, South back. Out and back legs averaged so steady drift cancels (sim: 1.99/1.97 px/s vs true 2.0). Reports px/s and angle; warns if axes > 20 deg from square.
- Guiding: solve drift d into West/North pulse ms with the 2x2 calibration matrix, x aggressiveness (RA/Dec, default 70%), skip below min move (0.15 px), clamp max pulse (2000 ms). Settled = within 1.5 px for 3 frames. Dither = random lock shift +/- N px. History 300 frames, RMS in px (BAS shows arcsec from guide focal length + camera pixel size).
- Link: guide copy binds UDP 127.0.0.1:47123; messages STATUS (reply "STATE n PAUSED n STAR n SETTLED n RMS x CAL n"), STOP, PAUSE, RESUME, DITHER. Main copy polls STATUS each second (40 ms timeout) and shows it in the Guider panel (group 14) with Pause / Resume / Dither and "Stop guiding before a GoTo" (default on; MountGoto% sends STOP).
- BAS guide mode: guideMode from Command$ "--guide"; title "QBCap Guider"; log QBCap_guide.log; no EFW; only groups 1,2,3,6,14; short toolbar with Guide / Stop guiding; RAW16, 1 s, gain 200 defaults; settings in QBCap_guide.txt (focal length default 200 mm, aggressiveness, min move, max pulse, cal step, dither px). Overlay: green box = guide star, yellow cross = lock point, click image to pick a star, RA (blue) / Dec (red) graph with auto range.
- Test: mock camera MOCK_GUIDE renders 3 stars with drift (RA 0.25 px/s + 3 px 8-min periodic error, Dec 0.05 px/s), 0.3 px seeing jitter, axes at 30 deg, 2 px/s guide rate, 0.3 s Dec backlash; harness RMS 0.5-0.6 px RA, 0.35 px Dec (seeing-limited); GUI calibrate + guide + link Pause/Resume/Dither all worked.
- Limit: camera picker still only ASI174 / ASI178 / ASI1600 names (guide camera must be one of those for now; ASI1600MM-Cool has no ST-4 port).

## Mount (planned next)
- Orion Atlas Pro AZ/EQ-G SynScan GoTo = Sky-Watcher AZ-EQ6 GT. Talked to it over WiFi with ~/Desktop/QBCap/mount/mounttest (read-only, built by mount/build_mount.sh): UDP 192.168.4.1:11880 (mount WiFi password 12345678 per Russell). Also has RS-232 / USB; Stellarium drove it before.
- Results: :e reply "=020B05" → firmware 2.11, mount code 0x05 (AZ-EQ6). NOTE: the :e answer is plain hex order (code = low byte of strtol), unlike positions which are 24-bit low-byte-first. Steps per turn 9,216,000 both axes (180 teeth × 51200; 0.1406"/step). Timer freq 53694 Hz. Positions 0, status '100' (motor board not initialised — needs init (:F) like SynScan Pro does on connect).
- First WiFi reply of a session can be garbled (first run gave "!0B05"); retry logic needed.
- Plan: 1) connect + read position (hint for first plate solve), 2) slew buttons + tracking on/off, 3) GoTo + solve-and-sync / centre target, 4) automatic RA turn for polar alignment; also a slow "cable check" swing. Equatorial mode assumed for imaging.

## Build
1. `sh build_lib.sh`  → libqbcap.so (needs ASICamera2.h, EFW_filter.h, libASICamera2.so, libEFWFilter.so in the folder)
2. `sh build_gpu.sh`  → libqbgpu.so (CUDA 12.0 nvcc; sm_50 GTX 745, sm_61 GTX 1070, sm_86 RTX 3050 + PTX)
3. Close/reopen QBCap.bas in QB64-PE (the IDE can save an old copy over a new file), compile, run.
USB rule: 99-qbcap-zwo.rules → /etc/udev/rules.d/ (needs the hidraw line for the EFW).
Plate solving needs astrometry.net (`sudo apt install astrometry.net`) — already installed.
PoleMaster: `sh install_polemaster.sh` once (fxload + /lib/firmware/qhy/POLEMASTER.HEX + /etc/udev/rules.d/85-qbcap-polemaster.rules) — done on his machine. libqhyccd.so sits in the QBCap folder (from github indilib/indi-3rdparty libqhy/x64, SONAME libqhyccd.so.20); QBCap dlopens it from its own folder.
Files copied to his machine lose the executable bit — tell him `chmod +x` for binaries.

## Working (tested on real hardware)
- Cameras: ASI178MM (48 fps full frame), ASI1600MM-Cool (18 fps, cooled to −9.6 °C), ASI1600MC; QHY PoleMaster (live view)
- Live preview, stretch, debayer, white balance, histogram, zoom, ROI/binning, RAW8/16
- Recording: SER and FITS sequence, frame/time limits, snapshots; files verified complete
- EFW: 5-slot (newer firmware, calibrate OK) and 8-slot (older firmware — do NOT calibrate; it homes at power-up). Per-wheel filter names in QBCap_filters.txt
- Master darks/flats: capture, save (masters/), load, applied to preview; recordings stay raw
- GPU: GTX 1070 (CUDA device 0) self-test OK, sharpness score 1.6 ms per 6.4 MP frame; lucky imaging (keep best %), focus/seeing graph; CPU fallback if no CUDA
- Live stacking (v0.7): ran on the ASI178 indoors (463 frames, sigma clip, alignment off); not yet tried on real stars
- Plate solving (v0.8): on Russell's machine, blind solves of web JPEGs in < 1 s each — Horsehead, M106, Crescent (NGC 6888), Dumbbell (M27); SynScan M42 FITS in 11 s
- Thermal panel only sends cooler settings to cooled cameras (fixed "ASI 3 invalid control type")
- Mount WiFi link (mounttest, read-only)

## Live stacking
- Toolbar "Live Stack" or Live Stack panel; Mean or Sigma clip (κ=3 from 5 frames), hot-pixel removal
- "Align on stars" checkbox (v0.71): off = frames stacked where they land (tests / no stars); FITS key STKALIGN T/F
- Star alignment: translation + rotation; mono full-res, colour as half-res RGB
- Save stack → stacks/Stack_<cam>_<date>_<N>x.fits (32-bit float; RGB cube for colour)

## Plate solving (v0.8)
- Plate Solve panel / toolbar button. Image: Live frame, Live stack, or Image file (FITS / JPEG / PNG); library source 4 = PoleMaster frame
- Index files: ~/Desktop/QBCap/index (4107–4119, 5200–5206, 52m1; ~60 GB). QBCap scans the folder and writes an explicit index list per run (non-index files ignored), widest quads first; never "inparallel"
- Two star lists: plain brightest peaks, and filtered (background map removed, nebula lumps and blank-border junk dropped). Each band runs with both lists in parallel; first success wins
- Camera images: Telescope scale hint (±25%) or Off; "Search near last solve first" (position hint, also for blind solves; whole-sky backup runs start after 8 s); 60 s limit with hint, 180 s blind
- Image files and PoleMaster frames: no scale hint (bands 1–30°, 20–60', 5–20'); PoleMaster's 11° field uses the small Tycho indexes
- Result: RA/Dec, field, rotation, arcsec/px; solved image with WCS → solves/Solve_<cam|File>_<date>.fits
- Tolerant .wcs reader (Russell's astrometry.net writes it differently from Ubuntu's 0.93); falls back to parsing solve-field's printout
- Work files in solve/ (qbsolve1..N.log = each run's output)

## Polar alignment (v0.9, PoleMaster-only since v0.10)
- Toolbar "Polar Align" opens the panel (collapses the others) and connects the PoleMaster if plugged in; otherwise the panel shows "PoleMaster not connected" + "Connect PoleMaster". Exposure 100–5000 ms, gain 0–100. The image area shows the PoleMaster feed while the panel is open; the main camera keeps running.
- PoleMaster view stretch: star stretch for star fields; flat/bright scenes shown at true brightness; red "SATURATED – lower the exposure / gain" warning when most of the frame is at full scale
- Steps: 1. any RA position, stars visible → "Step 1: solve here"; 2. turn the mount 60–90° in RA (either way) → "Step 2: solve again" (refuses < 15° or > 165°); 3. turn only the ALT/AZ knobs; "Keep solving" re-solves about once a second
- Readout: total error (red > 5', amber > 1', green < 1'; arcsec under 1'), "Alt: LOWER/RAISE x", "Az: move WEST/EAST x"
- Overlay: yellow ring = where the mount's RA axis points (fixed pixel), red cross = true pole of date; bring the cross into the ring
- Maths (C, qbcap.c step 8): camera orientation from each TAN WCS → precession J2000→date (IAU 1976) + GMST → Earth-fixed frame; rotation between the two frames gives the RA axis; its pixel stays fixed while adjusting
- PoleMaster module (qbcap.c step 9): dlopen libqhyccd.so; prefers a camera whose id contains "POLE"; single-frame loop thread, 8-bit; frame time = middle of exposure
- Main-camera polar-align code is still in the source (paCam = 1 path) but the panel no longer offers it
- Verified: maths sim vs astropy (0.0'–0.1'); GUI end-to-end on simulated pole sky; via QHY SDK demo camera at 31"/px: 29.2' total, LOWER 25.1' (true 25.0), EAST 15.0'; after adjusting LOWER 2.1' / EAST 59" (true 2.0' / 60")
- Polar-align solves do not save solved images and keep the status bar/log quiet
- Not handled: atmospheric refraction (pole appears ~1' higher); southern hemisphere untested

## Next
- Beta test on the real sky, then fix what it finds
- Mount control (above)
- Small: show EFW firmware version; confirm step on Calibrate; friendly message when calibrate fails
- Ideas: settings dialog (stub), refraction correction for polar align, gentler stretch option for daylight PoleMaster views

## Notes
- Log: QBCap.log next to the program (appends each session)
- libEFWFilter.so needs libudev but doesn't declare it — build_lib.sh links it explicitly

## Capture names + folder (2026-10-14)
- Captures go to <capture folder>/<Object>/<night date>/<Filter>/Object_Filter_Exposure_00001.fits (SER: ..._hhmmss.ser, snapshot ..._snap_hhmmss.fits). Example: M57/2026-10-13/Red/M57_Red_2min_00001.fits.
- Object = last confirmed GoTo target, or typed with the "Object: ... (change...)" button in Capture Format & Area. Filter = EFW slot name (left out with no wheel). Exposure tag 2min / 30s / 1.5s / 500ms.
- Night date: before noon counts as the previous evening, so one night stays in one folder.
- A repeat batch with the same name gets _run2, _run3 (no overwrite; the C library still numbers from 00001).
- Capture folder: File > Capture Folder... or the panel button; saved in QBCap_capture.txt; falls back to ./captures for the session if the folder is missing (drive unplugged).
- BAS only - no libqbcap.so rebuild needed.

## Orion StarShoot G3 as a main camera (step 12, libqbcap v14, 2026-10-16)
- Backups of the code before this change: old_versions/*.before-g3 (qbcap.c, QBCap.bas, QBCapRemote.bm, build_lib.sh). To undo: copy those back and run build_lib.sh.
- libssg3.so (ssg3_shim.c + Ben Gilsrud's orion_ssg3.c/.h from indi-3rdparty, LGPL) is loaded at run time with dlopen, like libqhyccd.so. Missing -> G3 simply not available; ZWO path unchanged (only 7 original lines touched, all equivalent for ZWO).
- build_lib.sh now also builds libssg3.so when the sources + libusb-1.0-0-dev are there (non-fatal if not). udev rule 99-orionssg3.rules (07ee, MODE 0666) must be in /lib/udev/rules.d on each machine.
- Camera list: G3Mono (4), G3Color (5); qc_find_camera("G3...") -> index 1000/1001; qc_open fills g.info (752x582, 16-bit, 8.6 um, cooled, ST4Port off) so FITS/SER/stack/solve need no change.
- G3 has no video mode: g3_cap_thread loops start exposure -> wait (20 ms steps, temp read every 2 s) -> download -> cap_frame_arrived. Gain/offset/cooler changes are queued and sent between frames. No abort command: Stop mid-exposure marks it stale; next start waits for it to end, then ssg3_drain() throws the data away.
- 16-bit full frame bin 1 only (BAS forces Format/Binning/ROI; auto exp/gain and USB bandwidth ignored). Colour G3 read raw as mono (sensor believed CMYG, not RGGB). ST-4 guiding through the G3 not done yet.
- Tested here: fake libssg3 harness + QBCap compiled with QB64-PE 4.6.0 under Xvfb via remote commands (connect, exp, gain, cooler, live 2 fps, snapshot FITS header OK). Not yet run with the real G3 in QBCap.
- Driver bug worked around in the shim: orion_ssg3_image_download's size check is inverted (rejects buffers larger than the frame).

## Standard Linux USB camera (V4L2) as a main camera (step 13, libqbcap v15, 2026-10-16)
- Backups before this change: old_versions/*.before-usbcam (qbcap.c, QBCap.bas, QBCapRemote.bm).
- Camera list entry "USBCam" (6). qbcap.c finds the first /dev/videoN offering raw 8-bit Bayer (BGGR/GBRG/GRBG/RGGB) or GREY at its largest size; mmap streaming, 4 buffers, capture thread with poll(). No extra library (kernel V4L2 API).
- Russell's camera: Microdia 0c45:6242 "USB20 Camera" (SN9C201 + MI1310 = MT9M111, 1.3 MP colour CMOS, ~3.6 um), driver gspca_sn9c20x, /dev/video0. Raw BA81 (BGGR) 1280x1024 at ~6.6 fps (driver delivers 1280x1023 - missing row blanked). JPEG/I420 only up to 640x480 (not used). No exposure or gain control exposed (sensor runs its own auto exposure); only brightness/contrast/saturation/hue/red+blue balance/gamma/flip - not wired into QBCap yet.
- QBCap maps ASI_EXPOSURE -> V4L2 exposure_absolute (100 us units) and ASI_GAIN -> gain, auto exp/gain, when a camera has them; otherwise says so. No temperature/cooler; BAS hides temperature for USBCam. 8-bit, full frame, bin 1 forced. Intended use: Moon/planets, SER recording + lucky imaging.
- Tested here with an LD_PRELOAD fake V4L2 device (BGGR test pattern displayed blue = debayer phase right, 6.4 fps, snapshot, stop/restart, G3 still fine). Not yet run with the real camera in QBCap.
- Display also shows temperatures in C and F (status bar, Thermal panel, target slider "-10 C (14 F)", remote sensor_temp_f).

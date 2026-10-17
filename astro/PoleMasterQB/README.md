# PoleMasterQB

QHY PoleMaster polar alignment for Linux, written in QB64-PE. It follows the
same steps as QHY's Windows PoleMaster program.

## Files

| File | What it is |
|---|---|
| `PoleMasterQB.bas` | the program (QB64-PE 4.6) |
| `ButtonUI.bi` / `ButtonUI.bm` | your button / mouse helper |
| `catalog_north.bi` / `catalog_south.bi` | 236 / 229 Hipparcos stars near each pole (V <= 8) |
| `pmcam.c`, `build_pmcam.sh` | C core: camera, simulator, star finder -> `libpmcam.so` |
| `libqhyccd.so` | QHY SDK (from indilib/indi-3rdparty, libqhy x64, SONAME libqhyccd.so.20) |
| `qhy/POLEMASTER.HEX`, `qhy/85-polemasterqb.rules`, `install_polemaster.sh` | one-time firmware + USB rule setup |

## Setup (once)

```
cd PoleMasterQB
sh build_pmcam.sh          # builds libpmcam.so
sh install_polemaster.sh   # fxload, firmware, USB rule (skips the rule if INDI/QBCap already has one)
```

Unplug and replug the PoleMaster; `lsusb | grep 1618` should show `1618:0941`.
Then open `PoleMasterQB.bas` in QB64-PE 4.6 and compile (F11). The folder path must not
contain spaces.

Close Ekos, PHD2 and QBCap first - only one program can hold the camera.

## Using it

0. **Start at HOME.** Counterweight bar straight down, scope pointing at the pole,
   then power on the SynScan hand controller. Rough polar align with a compass and the
   latitude scale so the pole star is in view.
1. **Connect > PoleMaster** (or **Connect > Simulator** to practise in daylight).
   Pick North/South, exposure and gain (night: about 1-2 s, gain 40-60), latitude and
   longitude (east positive) - or type a ZIP code in the **or ZIP** box and press Enter to
   fill them in. **Finished**.
2. **Double-click the pole star.** The star pattern is matched automatically
   (rotation, scale and mirror). Every red circle should hold a star; if not, turn it with
   the arrow keys / mouse wheel / `<` `>` buttons or **Mirror**. **Success**.
3. **RA axis.** Double-click a bright star away from the pole star. Turn the mount in RA
   with the hand controller (about 30 deg each time, 50-60 deg in total - small turns give a
   poor axis and the circles drift apart later), **Finished**,
   double-click the star again. Do it once more. The axis is fitted from every star that
   moved, not only the one you clicked. Slew back to HOME (the other RA direction, the
   same amount you turned): the star should follow the green circle. **Correct**.
4. **Rough alignment.** With the mount at home, double-click the pole star again, **Success**, then use the
   altitude / azimuth knobs to put the pole star in the small green circle.
5. **Precise alignment.** **Start Monitor**: the pole star and a second star are tracked
   in green boxes. Bring the red circle (pole) onto the green circle (mount axis). The
   panel shows the error and which way to turn each knob. **Finished**.
6. **Leave the mount at HOME** and run the SynScan star alignment. Not sure it got
   back exactly? Hand controller: Utility > Park Scope > Home Position.

Keep tracking on. Turn the mount with the hand controller, never the RA clutch.
If a tracked star is lost (knobs turned too fast), double-click it.

Settings are saved in `PoleMasterQB.ini`. Default site: Kitt Peak, AZ.

**ZIP lookup** uses api.zippopotam.us (the same lookup as AstroWeather; plain HTTP, curl
over HTTPS as the fallback). It needs internet, so set it up at home - the result is saved
in the ini file and works offline in the field. The ZIP's centre is rounded to 0.01 deg;
a general location is all polar alignment needs (the site only sets the "up" / "east"
directions and the refraction amount). Other countries: country code + postcode,
e.g. `GB SW1A`.

## PMQBauto: automatic RA axis (`PMQBauto.bas`, was PoleMasterQB2)

Same program, plus mount control, so step 3 needs no hand-controller turns.
Version 1 (`PoleMasterQB.bas`) is unchanged and still works.

Setup (once): `sh build_pmmount.sh` (builds `libpmmount.so`), then open
`PMQBauto.bas` and compile with F11.

The mount is driven with the same SynScan code as QBCap (WiFi, UDP 11880, or USB).
The address is `mount=` in `PoleMasterQB.ini` (default `192.168.4.1`). Only one program
can talk to the mount, so close the SynScan app and QBCap's mount connection first.

1. Steps 1-2 as before, plus **Mount > Connect mount**. Connecting stops the mount,
   then tracking is switched back on.
2. In step 3 pick the turn size (**2x20**, **2x30**, **2x40**; 2x30 is the default) and click
   **Auto RA axis**. The mount:
   - turns RA 5 deg as a test, then in steps of up to 15 deg to 30 and 60 deg;
   - after each step, fits the whole star field (not just one star) and checks that the
     camera turned as far as the mount's encoders say;
   - picks a bright star that stays in the frame and hands the three positions to the
     same axis solver as the manual mode;
   - slews back to where it started and places the overlay again, then goes straight on
     to the rough alignment (step 4).
3. Steps 4-6 as before (the knobs are still yours).

Safety:
- Only RA moves. Dec is never touched.
- The run never goes past twice the turn size, and no single move can be over 90 deg.
- The big **STOP** button or **Esc** stops both axes at once (tracking off). The run also
  stops if an axis stalls, the WiFi link drops, the mount refuses a command, the star field
  is lost (clouds), or the field turned a different amount than the mount (a slipping
  clutch). After a stop, **Return to the start position** slews back.
- If Dec reads more than 10 deg from where it was at power-up, the first click only
  warns (is the scope at HOME?). Click again to go ahead anyway.

**Go to HOME** (the **HOME** button at the foot of the panel, or Mount > Go to HOME)
slews back to where the mount was at power-up (RA 0, Dec 0 on the readout). Dec goes first,
bringing the tube back along the polar axis, then RA, so the tube can't swing into a tripod
leg. Tracking is switched off when it gets there. The first click shows how far each axis
will move; click again within 15 s to go. **STOP** or **Esc** halts it. This assumes the
mount was switched on at HOME, as in step 0.

**WiFi robustness (libpmmount version 2).** The "refused a move command" stops that QBCap's
log also shows came from late answers on the WiFi link being read as the answer to a newer
command. libpmmount now:
- throws away answers with the wrong length for the command they answer;
- tries each command 3 times over WiFi;
- retries a refused start once, after making sure the motor has stopped;
- ignores a position reading that jumped further than the mount can move (2 deg/s) unless
  it repeats.

On a test mount that drops and delays 16% of its answers, the old code finished 10 of 18
moves (7 refused, one move ended 60 deg past its target). The new code finished 18 of 18.
QBCap's `qbcap.c` has the old mount code and could take the same fix.

Practice in daylight: **Connect > Simulator**, then **Mount > Simulated mount**.
Everything is logged to `PoleMasterQB.log`, including each step's field fit and
axis estimate.

## Remote control (live sessions with Claude)

**Help > Remote control ON** (or start with `./PMQBauto --remote`) lets Claude drive the
program through files in the `remote` folder next to it. Claude writes `remote/cmd.txt`.
The program reads it twice a second, deletes it, runs the commands one per frame, and writes
`remote/reply.txt`. It also rewrites `remote/status.txt` every second, and saves
`remote/screen.png` on a `shot` command. An orange **REMOTE** badge sits at the right of the
status bar while it's on. It is off at every start unless `--remote` is given, and your own
**STOP** button and **Esc** always work.

Commands: `click X Y`, `dbl X Y` (screen pixels, as in screen.png), `dblframe FX FY` (camera
pixels), `key esc|left|right|m|z|f1`, `stop`, `home` (twice), `auto [20|30|40]`, `exp MS`,
`gain G`, `connect pm|sim|mount|simmount`, `disconnect cam|mount`, `track on|off`, `stars`,
`wait S`, `shot`, `status`, `id TEXT`. The last line of cmd.txt must be `end`.

## Accuracy

Star positions are apparent places for the current date (precession, nutation,
aberration, proper motion), within 0.4" of astropy. **Refraction correction** (off by
default) shifts the target towards the horizon by the refraction at your latitude, like
the Windows program does.

## Self test

```
./PoleMasterQB --selftest          (or --selftest south)
```

Runs the whole procedure on the simulator by itself (a mount 23' low and 17' west) and
checks each step against the simulator's truth. Last run:

| Step | North | South |
|---|---|---|
| overlay, worst star vs truth | 0.46 px | 0.69 px |
| RA axis centre vs truth | 3.1" | 1.6" |
| rough error readout vs truth | within 0.05' | within 0.05' |
| after following the readout twice | 3.9" true error | 10.4" true error |

PMQBauto: `./PMQBauto --selftest auto` (or `--selftest south auto`) does step 3
with the simulated mount. The self test now turns refraction off for itself, since the
simulator's truth has no refraction in it (with refraction on in the ini, the rough step
"fails" by exactly the refraction amount). Last run (2x30):

| Step | North | South |
|---|---|---|
| automatic RA axis centre vs truth | 2.2" | 2.9" |
| back at the start | 0.0000 deg | 0.0000 deg |
| after following the readout twice | 4.2" true error | 12.8" true error |

2x20 and 2x40 also pass (2.6" and 1.5").

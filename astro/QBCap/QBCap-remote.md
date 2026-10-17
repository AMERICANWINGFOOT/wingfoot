# QBCap remote control (v0.12)

QBCap reads commands from a text file in its own folder, so Claude (or a script)
can run it through the file bridge. No network and no extra software.

| File | Direction | What |
|---|---|---|
| `QBCap_cmd.txt` | in | Commands, one per line. QBCap waits until the file stops growing, reads it, then **deletes** it. |
| `QBCap_reply.txt` | out | One line per command: `time  command  ->  OK / ERR / WAIT ...` (new file each session) |
| `QBCap_status.txt` | out | `key = value` lines, rewritten every 2 s (camera, exposure, filter, recording, solve, mount, guider, queue) |
| `QBCap_screen.png` | out | Written by `SCREENSHOT` - exactly what is on the screen |
| `QBCap.log` | out | Every remote command and result is copied in, marked `REMOTE` |
| `QBCap_remote.txt` | setting | `remote = on` / `off` |

## Safety
- **The mount only moves by remote when "Allow remote mount moves" is ticked by hand**
  (Tools > Remote Control, or the Remote control panel). It is off every time QBCap starts.
  With it off, `GOTO` and `TRACK ON` are refused. `MSTOP`, `TRACK OFF` and `ABORT` always work.
- A `QBCap_cmd.txt` left over from before QBCap started is **not run** - it is renamed `QBCap_cmd.old`.
- A failed command (`ERR`) clears the rest of the queue, so a batch never carries on after a failed step.
- The mouse always works. The Remote panel has **Pause queue** and **Clear queue**.
- `QUIT` runs the normal ShutDown (recording saved, solver stopped, mount stopped, cooler off).
- Menu bar shows `REMOTE on` / `REMOTE busy` / `REMOTE paused` / red `REMOTE + MOUNT`.

## Commands
```
PING | STATUS | SCREENSHOT [name] | SHOW panel | LOG text | HELP
CONNECT [ASI174|ASI178|ASI1600|G3Mono|G3Color|USBCam|QHYCam] | DISCONNECT | LIVE [ON|OFF] | STOP
EXP 500ms | EXP 2s | EXP 2min | GAIN n | OFFSET n | BIN 1-4 | FORMAT RAW8|RAW16 | ROI FULL|HALF|QUARTER|640
COOLER ON|OFF | COOLTEMP -10
FILTER 3 | FILTER Red | OBJECT M57 | SAVEAS SER|FITS | LIMIT NONE|100|500|1000|5000|30S|1MIN|5MIN
CAPTURE [frames] | SNAP | DARK [10|20|50|100] | FLAT [n] | STRETCH | STACK START|STOP|SAVE|RESET
SOLVE                      live frame; also syncs the mount when it is connected
MOUNT CONNECT|DISCONNECT | MSTOP | FIND name | CENTRE ON|OFF
GOTO name | TRACK ON [LUNAR] | TRACK OFF       (need "Allow remote mount moves")
GUIDE PAUSE|RESUME|DITHER|STOP|STATUS          (QBCap guide window, UDP link)
WAIT 30s | WAIT FILTER|CAPTURE|SOLVE|GOTO|MASTER|COOL|SETTLE [give-up time]
RUN plan.txt | CLEAR | ABORT | QUIT
```
- Exposure, gain, offset, format, filter and object are refused while recording (file names carry them).
- `CAPTURE 20` records exactly 20 frames (any number); plain `CAPTURE` uses the panel's Limit.
- `WAIT` holds the queue. Default give-up times: FILTER 90 s, SOLVE 240 s, GOTO 600 s,
  COOL 20 min, SETTLE 3 min, CAPTURE / MASTER none. A wait that gives up is an `ERR`.
- `SHOW Mount` (or Guider, Plate Solve, Filter, Remote...) opens that panel so a screenshot shows it.
- `CLEAR`, `ABORT`, `MSTOP` run the moment the file is read. A file holding only
  `STATUS / SCREENSHOT / PING / HELP / SHOW` lines also runs at once, even during a WAIT.
  Anywhere else every line keeps its place in the order.
- `RUN plan.txt` puts a command file from the QBCap folder at the front of the queue, in order.
  This is the start of the sequencer: the sequencer will use these same commands.

## Example plan (M57 in three filters)
```
OBJECT M57
SAVEAS FITS
FILTER Red
WAIT FILTER
EXP 2min
CAPTURE 20
WAIT CAPTURE
FILTER Green
WAIT FILTER
CAPTURE 20
WAIT CAPTURE
FILTER Blue
WAIT FILTER
CAPTURE 20
WAIT CAPTURE
SCREENSHOT
```

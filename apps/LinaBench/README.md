# Linabench v1.4

A Cinebench-style CPU render benchmark for Linux, written in QB64-PE and C.

Linabench ray traces a fixed scene of 38 spheres on a checker floor. Soft shadows come from an area light, reflections go up to 4 bounces deep, and every pixel gets 64 samples. The 960x540 image is split into 32x32 tiles that are rendered by every CPU thread at once. The score measures how fast the processor does the math; the graphics card only displays the finished image.

---

## Files

| File | Purpose |
|---|---|
| `Linabench.bas` | GUI version (window, live render, graphs) |
| `LinabenchCLI.bas` | Headless console version (terminal / SSH, no display needed) |
| `linabench.h` | Shared C render kernel (pthreads), used by both programs |
| `linabench_results.csv` | Created automatically, one line per finished run |

Keep all three source files in the same folder.

## Requirements

- Linux (uses pthreads, `/proc` and `/sys`)
- QB64-PE 4.5.0
- No extra libraries needed

## Building

1. Open `Linabench.bas` in QB64-PE and compile. Do the same for `LinabenchCLI.bas` if you want the console version.
2. QB64-PE's **C++ optimization** option is not required. The header forces `-O2` on the render kernel itself, so scores are the same either way.
3. If the compiler can't find the header, edit the `Declare Library "./linabench"` line to match the path form your other header-based projects use.

---

## GUI version

### Keys

| Key | Action |
|---|---|
| **M** | Multi-core run using the current thread count |
| **S** | Single-core run (1 thread) |
| **L** | 10-minute loop: repeated multi-core runs for thermal and sustained testing |
| **W** | Thread scaling sweep: 1, 2, 4, 8 ... all threads |
| **+ / -** | Change the thread count used by M and L |
| **Esc** | Abort the current run, or quit when idle |

### The panel

- **CPU temp**: package temperature from hwmon (`coretemp`, `k10temp` or `zenpower`), with the session maximum.
- **CPU clock**: average clock across all logical CPUs. Low when idle, which is normal.
- **Governor**: CPU frequency governor. This turns red only when it really holds clocks down (see Troubleshooting).
- **Run clock (top N)**: during a run, the average clock of the N busiest cores.
- **Multi-core / Single-core**: latest scores.
- **MP ratio**: multi-core score divided by single-core score.
- **Image check**: compares the image checksum from a single-core run and a multi-core run. They must match.

While a run is going, yellow boxes mark the tiles being rendered. Tiles are rendered from the center outward.

### Scaling sweep (W)

The sweep runs each thread count in turn and fills in a table of threads, score, scaling relative to 1 thread, and a bar. The 1-thread and all-thread results also fill in Single-core, Multi-core, MP ratio and Image check, so one sweep gives you the complete picture.

### 10-minute loop (L)

The loop repeats multi-core runs for 10 minutes and graphs two lines on a shared time axis:

- **Blue**: the score of each run, auto-scaled so small droops show clearly.
- **Orange**: CPU temperature on a 20-100 C scale, sampled every 2 seconds.

When the loop finishes, the log shows the number of runs, the min and max score, and the **drop %** between them. A drop of a few percent is normal. A large drop means the CPU is thermal throttling.

---

## CLI version

```
./LinabenchCLI          multi-core run, all threads
./LinabenchCLI -m 8     multi-core run with 8 threads
./LinabenchCLI -s       single-core run
./LinabenchCLI -w       thread scaling sweep
./LinabenchCLI -h       help
```

The CLI prints a progress bar of dots, then a result line with the score, seconds, MHz, peak temperature and checksum. It writes to the same CSV as the GUI.

---

## One benchmark at a time

Only one Linabench, GUI or CLI, can benchmark on a machine at a time. A second instance shows:

```
BUSY: another Linabench (GUI or CLI) is benchmarking on this machine
```

This prevents overlapping runs, which split the CPU and give false low scores. The lock is a kernel `flock` on `/tmp/linabench.lock`. It is released automatically when a program exits, even if it crashes, so it can never get stuck.

---

## Results file

Every finished run is appended to `linabench_results.csv` in the current folder. Aborted runs are not logged.

| Column | Meaning |
|---|---|
| `date`, `time` | When the run finished |
| `host` | Machine hostname, so one file can hold several computers |
| `cpu` | CPU model |
| `version` | Linabench version |
| `mode` | `multi`, `single`, `loop` or `sweep` |
| `threads` | Threads used |
| `score` | Result in points |
| `seconds` | Render time |
| `avg_mhz` | Average clock of the busiest N cores during the run (v1.4 and later; earlier rows averaged all cores) |
| `peak_temp_c` | Highest CPU temperature during the run |
| `governor` | CPU frequency governor |
| `checksum` | Image checksum |

The file opens in any spreadsheet program.

---

## Understanding the results

**Score** is rays traced per second divided by 100,000. Higher is better. Scores are comparable between machines running any v1.x version, because the render kernel has not changed.

**Checksum.** Every correct run produces the identical image, whatever the thread count or machine:

```
2D5D94A4
```

A different checksum means the CPU or memory made a calculation error. That usually points to an unstable overclock, bad RAM or overheating. This makes Linabench a quick stability check too.

**Scaling.** On a healthy CPU, scores roughly double from 1 to 2 to 4 threads, up to the physical core count. Hyper-Threading threads beyond that add a smaller gain, since they share each core's floating-point units.

### Reference: Intel Core i7-5960X (8 cores / 16 threads)

Rampage V Extreme, Linux Mint, `intel_cpufreq` / `schedutil`, about 3.5 GHz under load.

| Threads | Score | vs 1 thread |
|---|---|---|
| 1 | 56.3 | 1.00x |
| 2 | 112.3 | 1.99x |
| 4 | 224.5 | 3.99x |
| 8 | 434.6 | 7.72x |
| 16 | 505-513 | about 9.0x |

Near-linear scaling up to 8 cores, and Hyper-Threading adds about 17%. Repeat runs vary by under 1%.

---

## Troubleshooting

**Very low scores.** Check for another heavy program running at the same time. Two Linabench copies from before v1.4 could overlap and roughly halve each other's score; v1.4 blocks that.

**Governor shown in red.** Under the `acpi-cpufreq` or `intel_cpufreq` drivers, the `powersave` governor pins clocks at minimum. Switch it with:

```
sudo cpupower frequency-set -g performance
```

Under `intel_pstate` or `amd-pstate`, `powersave` is the normal dynamic default and is not flagged.

**CPU temp shows n/a.** No supported hwmon sensor was found. Load the sensor driver (for Intel, `sudo modprobe coretemp`) or run `sensors-detect` from the `lm-sensors` package.

**CPU clock n/a, or a flat value.** Some virtual machines have no cpufreq data. Linabench falls back to `/proc/cpuinfo`, which may show only the base clock.

**BUSY message when nothing is running.** Check for a hidden or background Linabench process (`ps aux | grep -i linabench`). The lock releases as soon as that process ends.

**Header not found at compile time.** See Building, step 3.

---

## Technical notes

- **Scene**: 35 small spheres in a 7x5 grid, 3 large mirror spheres, and a checkered floor. A 2.5x2.5 area light gives 8 soft-shadow samples per hit, reflections go up to 4 bounces, and each pixel gets 8x8 = 64 samples.
- **Work per frame**: 303,837,684 rays.
- **Threading**: worker threads take tiles from a shared atomic counter, so fast threads simply take more tiles.
- **Determinism**: each pixel seeds its own random number generator from its position, so the image is bit-identical at any thread count.
- **Timing**: `CLOCK_MONOTONIC`, from starting the threads until the last tile finishes.

---

## Version history

| Version | Changes |
|---|---|
| 1.0 | First release: tile ray tracer, multi-core and single-core runs, 10-minute loop, image check |
| 1.1 | Kernel forced to `-O2` inside the header (full speed without QB64's optimization option), shorter CPU name |
| 1.2 | Clock and governor readout, results CSV, thread scaling sweep |
| 1.3 | Loop graph (score and temperature), fixed two-decimal formatting, `LinabenchCLI` headless version |
| 1.4 | Busiest-core clock measurement, one-benchmark-at-a-time lock |

## Possible future work

- An OpenCL GPU version: the same scene on the graphics card, on the same score scale, with per-GPU selection.

# wingfoot

Russell's QB64-PE work: apps, libraries, graphics experiments and astronomy
tools, with their companion C, CUDA and Vulkan code. Built on Linux Mint with
QB64-PE 4.6.

Each project folder is self-contained. Shared helpers such as ButtonUI and
GaugeUI are copied into every project that uses them, because the copies
differ slightly between projects. Open the `.bas` file in a folder and it
should compile with the includes beside it.

Only source is kept here. Compiled programs, `.so` libraries, zips, captured
images and data files are left out (see `.gitignore`) and rebuild from the
source and build scripts.

## apps/

| Folder | What it is |
|---|---|
| CPUInfo | CPU info and monitor (ButtonUI, GaugeUI) |
| CPULoad | CPU load and thermal test with `loadtest.h` pthread helper |
| DiskInfo | Disk model, capacity, SMART health and throughput |
| GPUInfo | NVIDIA multi-GPU monitor (`GPU_Info.bas`) and LCARS-style `USSGpuMon.bas` |
| LinaBench | CPU render benchmark for Linux, GUI and CLI |
| HexEdit | GUI hex editor |
| IndexViewer | Star index viewer with CUDA helper (`idxgpu.cu`) |
| NotePad | NotePad - QB64-PE Edition V3.2 |
| AstroWeather | Astronomy weather app plus WeatherGUI |
| AVIPlay | AVI player modules |
| Calculator, Calendar, DateTimeCalc, KaratsubaCalc | Calculators built on ButtonUI |
| Enigma | Enigma-like rotor cipher, including the 256-symbol version |
| PngToIco, PngToIco-v2 | PNG to ICO converter (v2 adds INI settings) |
| RFS | Custom USB stick drive format, RFSGui V1.1, V1.4 and V1.5 |
| RFS-v1 | First RFSGui version |
| TextReader | Book reader with GlyphFont |
| TychoConv | Tycho-2 star catalog converter |

## graphics/

| Folder | What it is |
|---|---|
| FishTank | GPU aquarium, CUDA version plus `FishTankVK` Vulkan version |
| QBScope | Analog oscilloscope for strange attractors, plus `QBScopeVK` |
| TimeVortex | Audio-reactive time vortex, CPU version plus `VortexVK` |
| RayGPU | CUDA ray caster |
| RayVK | Vulkan compute ray caster |
| RayMaze | Ray caster maze on the CUDA engine |
| GPU3D-CUDA, GPU3D-Vulkan | GPU3D pixel-placed 3D shape library, CUDA and Vulkan builds |
| W3, XYZView | W3 wireframe 3D helper and XYZ point viewer |
| OBJ3, OBJ3-OptButton | Wavefront .obj helper (second has the OptButton UI) |
| OFFViewer | OFF/OBJ viewer using OpenGL VBOs |
| Maxwell | Maxwell and Schrodinger simulations |
| SpriteLib | SPR sprite library, demo and QB64 Invaders |
| DeluxeQBPaint | Deluxe Paint port work |

## tools/

| Folder | What it is |
|---|---|
| Z64 | Z64 archiving pipeline (picker, chunker, pack, unpack, unchunker, z64go) |
| Z64Pak, Z64Compress, Z64Png | Z64 GUI front ends |
| SERTools | SER video player, stacker and diagnostics |

## lib/

| Folder | What it is |
|---|---|
| ButtonUI | ButtonUI mouse/button helper with demo |
| MemHelper | MemHelpers and IniHelpers with demo |
| TextHelpers | Text helper routines with demo |
| GateCalc | Gate, Adder and ALU (8/32/64/128-bit) logic-gate libraries and calculators |

## astro/

| Folder | What it is |
|---|---|
| QBCap | ZWO camera capture app with C library, CUDA helper, mount control, sequencer (`QBCapSeq`) and remote interface (`QBCapRemote`) |
| EFWController | ZWO EFW Filter Wheel Controller v2 |
| QBGuide | PHD2-style ST-4 autoguider: any ZWO camera, Orion StarShoot Autoguider (openssag) and original QHY5; simulator, bullseye target view |
| PoleMasterQB | QHY PoleMaster polar-alignment app (`PoleMasterQB.bas`) and auto version `PMQBauto.bas`, with pmcam/pmmount C libraries |
| G3 | Orion StarShoot G3 camera test app with `orion_ssg3` driver and shim |
| SSAIO | Orion StarShoot All-in-One camera test (libssaio over the QHY SDK), plus `fx2/` QHY5-II firmware notes and disassembler |

## Notes

- Location values in the sample `.ini` files are set to Kitt Peak, AZ.

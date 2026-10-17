GPUZip - multi-GPU folder compressor (QB64-PE 4.6 + CUDA)
==========================================================

Files
  GPUZip.bas     QB64-PE front end (GUI + command line)
  gpuzip.cu      CUDA/C++ helper: GPU compressor, CPU codec, CRC32, folder scan
  gpuzip.h       C header QB64 reads through Declare Library "./gpuzip"
  libgpuzip.so   prebuilt helper (CUDA 12.0, sm_50 / sm_61 / sm_86 + PTX)
  build.sh       rebuilds libgpuzip.so (needs nvcc: sudo apt install nvidia-cuda-toolkit)

Run
  1. Keep this folder path free of spaces (QB64 make breaks on them).
  2. Open GPUZip.bas in the QB64-PE IDE and press F5.
     The prebuilt .so should load as-is. If it won't, run ./build.sh and compile again.
  3. Source folder -> Compress, Open archive -> Extract, Benchmark.
     Mode button cycles through: All GPUs, GPU 1 only, GPU 2 only, Hybrid (GPUs + CPU), CPU.

Command line (after compiling)
  ./GPUZip c ~/somefolder ~/somefolder.gpz [mode]
  ./GPUZip x ~/somefolder.gpz ~/restore_here
  ./GPUZip l ~/somefolder.gpz
  ./GPUZip b ~/somefolder
  mode: -2 hybrid, -1 CPU, 0 all GPUs, 1..n one GPU

How the work is split
  The folder is read as one solid stream and cut into 64 KB chunks. Each chunk is
  compressed independently as a standard LZ4 block. Chunks go out in groups from a
  single queue, and each GPU takes 256 chunks at a time, so a faster card ends up
  with more of them. The GPU kernel runs one warp per chunk. The warp checks 32
  positions at once against a hash table in shared memory. Each GPU keeps two batches
  in flight, so the next copy over PCIe overlaps the current kernel.
  Decompression runs on the CPU, so a .gpz extracts fine on a machine with no GPU.
  The "work split" line in the log shows what share each card handled.

Checked here (in the cloud box, which has no GPU)
  - The GPU warp algorithm was emulated on the CPU, and every block it produced
    decoded byte-exact with the reference LZ4 decoder.
  - CUDA code compiles for sm_50/61/86 with 32 registers, 32 KB shared memory
    per block and no spills.
  - GPUZip.bas compiles in QB64-PE 4.6.0. A compress, list and extract round trip
    of a 1,367-entry folder matched the original exactly under diff -r, including
    empty folders, empty files and names with spaces.
  - A corrupted archive is caught and stops the extract. File contents are
    CRC32-checked.
  - Disk full: compress warns before starting if the target drive may be too small,
    and a write failure stops cleanly with the real reason and removes the partial
    archive. Unreadable source files are skipped and listed in the log.
  Not checked yet: running the kernel on real NVIDIA hardware.

#!/bin/sh
# Build libqbgpu.so (the optional CUDA part of QBCap).
# Needs the CUDA toolkit (nvcc), e.g.:  sudo apt install nvidia-cuda-toolkit
# Real code for each of Russell's cards, plus PTX so newer cards can still run it:
#   sm_50 = GTX 745 (Maxwell)   sm_61 = GTX 1070 (Pascal)   sm_86 = RTX 3050 (Ampere)
# If this library is missing, QBCap still works - it just scores frames on the CPU.
set -e
cd "$(dirname "$0")"
command -v nvcc >/dev/null || { echo "nvcc not found - install the CUDA toolkit first"; exit 1; }

nvcc -O2 -shared -Xcompiler -fPIC \
     -gencode arch=compute_50,code=sm_50 \
     -gencode arch=compute_61,code=sm_61 \
     -gencode arch=compute_86,code=sm_86 \
     -gencode arch=compute_86,code=compute_86 \
     -Wno-deprecated-gpu-targets \
     -o libqbgpu.so qbgpu.cu

echo "built libqbgpu.so  (GTX 745 / GTX 1070 / RTX 3050)"

#!/bin/bash
# Builds libgpuzip.so next to GPUZip.bas.
# Targets: sm_50 (GTX 745), sm_61 (GTX 1070), sm_86 (RTX 3050) + PTX for newer cards.
cd "$(dirname "$0")"
NVCC=nvcc
[ -x /usr/local/cuda/bin/nvcc ] && NVCC=/usr/local/cuda/bin/nvcc
$NVCC -O3 -std=c++14 -shared -Xcompiler -fPIC -Wno-deprecated-gpu-targets \
  -gencode arch=compute_50,code=sm_50 \
  -gencode arch=compute_61,code=sm_61 \
  -gencode arch=compute_86,code=sm_86 \
  -gencode arch=compute_86,code=compute_86 \
  -Xcompiler -pthread -o libgpuzip.so gpuzip.cu && echo "built libgpuzip.so"

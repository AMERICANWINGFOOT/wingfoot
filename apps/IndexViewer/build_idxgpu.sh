#!/bin/sh
# Builds libidxgpu.so for IndexView.bas.
# Targets: sm_50 (GTX 745), sm_61 (GTX 1070), sm_86 (RTX 3050) + PTX for newer cards.
# cudart is linked statically, so QB64 needs no extra -lcudart.
set -e
cd "$(dirname "$0")"

nvcc -O3 -shared -Xcompiler -fPIC -Wno-deprecated-gpu-targets \
  -gencode arch=compute_50,code=sm_50 \
  -gencode arch=compute_61,code=sm_61 \
  -gencode arch=compute_86,code=sm_86 \
  -gencode arch=compute_86,code=compute_86 \
  -Xlinker -soname=libidxgpu.so \
  -o libidxgpu.so idxgpu.cu

echo "Built libidxgpu.so - installing to /usr/local/lib (needs sudo)"
sudo cp libidxgpu.so /usr/local/lib/
sudo ldconfig
echo "Done. Keep libidxgpu.so and libidxgpu.h next to IndexView.bas for compiling."

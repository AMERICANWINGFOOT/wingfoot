# Makefile - GPU3D library (libg3d.so)
#
#   make            Vulkan build: any card - AMD Radeon, Intel Arc, NVIDIA
#   make cuda       CUDA build: NVIDIA cards only, can share a frame across several
#   make shader     rebuild g3d_draw_spv.h after editing g3d_draw.comp
#   make check      show the Vulkan cards this machine has
#   make clean      remove libg3d.so
#
# Needs for the Vulkan build:  sudo apt install g++ libvulkan-dev
# Needs for make shader:       sudo apt install glslang-tools
# Needs for make check:        sudo apt install vulkan-tools
# Both builds make the same libg3d.so with the same functions, so the QB64 files don't change.

CXX      ?= g++
NVCC     ?= $(shell command -v nvcc 2>/dev/null || echo /usr/local/cuda/bin/nvcc)
CXXFLAGS := -O2 -fPIC -Wall -Wno-unused-function
CUFLAGS  := -O2 -Wno-deprecated-gpu-targets \
            -gencode arch=compute_50,code=sm_50 -gencode arch=compute_50,code=compute_50 \
            -Xcompiler -fPIC
LIB      := libg3d.so
COMMON   := g3d_math.h g3d_common.h

.PHONY: all vulkan cuda shader check clean

all: vulkan

vulkan: $(COMMON) g3d_vk.cpp g3d_draw_spv.h
	$(CXX) $(CXXFLAGS) -shared -o $(LIB) g3d_vk.cpp -lvulkan
	@echo "Built $(LIB) (Vulkan) with $$(nm -D $(LIB) | grep -c ' T g3_') g3_ functions"

cuda: $(COMMON) g3d.cu
	$(NVCC) $(CUFLAGS) -shared -o $(LIB) g3d.cu
	@echo "Built $(LIB) (CUDA) with $$(nm -D $(LIB) | grep -c ' T g3_') g3_ functions"

shader: g3d_draw.comp
	glslangValidator -V --target-env vulkan1.0 --vn g3d_draw_spv -o g3d_draw_spv.h g3d_draw.comp

check:
	@vulkaninfo --summary 2>/dev/null | grep -E 'deviceName|deviceType|driverName' || echo "vulkaninfo not found or no Vulkan driver (sudo apt install vulkan-tools)"
	@lspci -k 2>/dev/null | grep -A3 -i -E 'vga|3d controller' | grep -E 'VGA|3D|Kernel driver' || true

clean:
	rm -f $(LIB)

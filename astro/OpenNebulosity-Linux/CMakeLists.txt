# OpenNebulosity - Linux build
#   mkdir build && cd build && cmake .. && make -j$(nproc)
cmake_minimum_required(VERSION 3.16)
project(OpenNebulosity CXX C)

set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS ON)          # gnu++14: the original code relies on GNU extensions
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

find_package(wxWidgets 3.0 REQUIRED COMPONENTS aui propgrid html adv net core base xml)
include(${wxWidgets_USE_FILE})
find_package(PkgConfig REQUIRED)
pkg_check_modules(CFITSIO REQUIRED cfitsio)
pkg_check_modules(LIBRAW  REQUIRED libraw)
pkg_check_modules(LIBUSB  REQUIRED libusb-1.0)
find_package(OpenMP REQUIRED)
find_package(Threads REQUIRED)
find_path(FREEIMAGE_INCLUDE FreeImage.h REQUIRED)
find_library(FREEIMAGE_LIB freeimage REQUIRED)

set(SRC ${CMAKE_SOURCE_DIR}/nebulosity4)

# Shared processing/UI code plus the Linux-capable camera drivers.
# Drivers whose SDKs are Windows/macOS-only are replaced by src/linux_camstubs.h.
set(NEB_SOURCES
  APyTools.cpp CIM.cpp CamToolDialogs.cpp DSSView.cpp LRGB.cpp Nebulosity.cpp
  alignment.cpp autoalign.cpp camera.cpp canon_cr2.cpp clock.cpp debayer.cpp
  display.cpp drizzle.cpp dummy.cpp ext_filterwheel.cpp file_tools.cpp focus.cpp
  focuser.cpp geometry.cpp greyc.cpp image_io.cpp image_manip.cpp image_math.cpp
  macro.cpp main_classes.cpp manual_color_camera.cpp osxfuncs.cpp preferences.cpp
  preprocess.cpp preview.cpp quality.cpp reconstruct.cpp scripts.cpp setup_tools.cpp
  # cameras
  simulator.cpp ZWOASI.cpp
)
list(TRANSFORM NEB_SOURCES PREPEND ${SRC}/)

add_executable(nebulosity ${NEB_SOURCES})
target_compile_definitions(nebulosity PRIVATE __LINUX__)
target_include_directories(nebulosity PRIVATE
  ${SRC} ${SRC}/cameras ${CFITSIO_INCLUDE_DIRS} ${LIBRAW_INCLUDE_DIRS}
  ${LIBUSB_INCLUDE_DIRS} ${FREEIMAGE_INCLUDE})
# The 2000s-era code needs these to build quietly with modern GCC.
target_compile_options(nebulosity PRIVATE -fpermissive -w)
target_link_libraries(nebulosity PRIVATE
  ${wxWidgets_LIBRARIES} ${FREEIMAGE_LIB}
  ${CFITSIO_LIBRARIES} ${LIBRAW_LIBRARIES} ${LIBUSB_LIBRARIES}
  ${SRC}/linux/zwo/libASICamera2.a
  OpenMP::OpenMP_CXX Threads::Threads stdc++ m)

# App icon (Linux has no resource icons); copied next to the program
add_custom_command(TARGET nebulosity POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different ${SRC}/linux/share/nebulosity.png $<TARGET_FILE_DIR:nebulosity>/nebulosity.png)

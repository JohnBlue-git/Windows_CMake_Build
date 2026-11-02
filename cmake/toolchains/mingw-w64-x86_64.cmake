# Cross-compile for 64-bit Windows with MinGW-w64 on a Linux host.
#
#   cmake -S . -B build/mingw -G Ninja \
#         -DCMAKE_TOOLCHAIN_FILE=cmake/toolchains/mingw-w64-x86_64.cmake
#
# Uses the "-posix" compiler variant so std::thread is available (Debian/Ubuntu
# also ship a "-win32" variant). The GCC runtime (libgcc, libstdc++,
# libwinpthread) is linked statically, so ThreadDemo.exe and libMyLibrary.dll
# run on a clean Windows without extra DLLs next to them.

set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

set(MINGW_TRIPLE x86_64-w64-mingw32)
set(CMAKE_C_COMPILER   ${MINGW_TRIPLE}-gcc-posix)
set(CMAKE_CXX_COMPILER ${MINGW_TRIPLE}-g++-posix)
set(CMAKE_RC_COMPILER  ${MINGW_TRIPLE}-windres)

set(CMAKE_FIND_ROOT_PATH /usr/${MINGW_TRIPLE})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

set(CMAKE_EXE_LINKER_FLAGS_INIT    "-static")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-static")

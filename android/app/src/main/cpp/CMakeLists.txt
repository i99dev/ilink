# dash NDK module. Currently owns tamper probes only; crypto migration
# (PBKDF2, AES-GCM, XOR-masked CarTable buffer) grows into this module
# as separate source files and gets linked in without touching the
# build config.
#
# Output: libdash_secrets.so shipped under lib/<abi>/ in the APK.
# Load point: com.i99dev.ilink.security.NativeSecrets.<clinit>
cmake_minimum_required(VERSION 3.22.1)

project(dash_secrets LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Keep symbols local unless explicitly exported via JNIEXPORT — reduces
# the attack surface for `objdump -T` enumeration of internals.
add_compile_options(
    -fvisibility=hidden
    -fstack-protector-strong
    -Wall
    -Wextra
    -Wno-unused-parameter
)

# Release optimisation: size over speed for this small probe module.
# When crypto functions land, reassess.
if(NOT CMAKE_BUILD_TYPE STREQUAL "Debug")
    add_compile_options(-Oz -fomit-frame-pointer)
    # Strip symbols from the shared lib after link.
    add_link_options(-Wl,-x -Wl,--gc-sections)
endif()

add_library(dash_secrets SHARED
    secrets.cpp
)

# Android system logging (__android_log_print). `log` is part of the NDK
# sysroot and doesn't need a package install.
find_library(log-lib log)

target_link_libraries(dash_secrets
    ${log-lib}
)

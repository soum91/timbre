cmake_minimum_required(VERSION 3.22.1)
project(timbre_tv LANGUAGES CXX)

# Compile the original Timbre engine unmodified, alongside a small JNI adapter.
get_filename_component(DSP_SOURCE_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../NativeDSP" ABSOLUTE)

add_library(timbre_native SHARED
    timbre_jni.cpp
    "${DSP_SOURCE_DIR}/TimbreDSP.cpp")

target_include_directories(timbre_native PRIVATE "${DSP_SOURCE_DIR}")
target_compile_features(timbre_native PRIVATE cxx_std_17)
target_compile_options(timbre_native PRIVATE -O2 -Wall -Wextra)

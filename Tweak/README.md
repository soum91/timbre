# Timbre Audio, Stage 2 (experimental)

Target: Dopamine rootless, iOS 16.1.1. Build on a configured Theos installation:

    cd Tweak
    make clean package THEOS_PACKAGE_SCHEME=rootless

This is NOT a working system-wide EQ yet. The hook is installed but DSP is deliberately
**disabled**. It has not been tested on iOS, and AudioUnitRender may not cover the
output route used by mediaserverd. Do not install on a daily-use device without
recovery access. The actual hook point must be validated against the target OS.

Remaining: safe per-stream DSP state and lifecycle, validated sample formats,
configuration IPC, DSP initialization off audio thread, control app integration,
rootless device testing, and verified package build.

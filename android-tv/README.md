# Timbre TV (Android 12 prototype)

An experimental Android TV controller for the system's available audio session
equalizer. This is a new Android implementation, not a binary port of the iOS
`AudioUnitRender` hook.

The original `NativeDSP/TimbreDSP.cpp` now also builds into the APK through
Android NDK and JNI for app-owned interleaved Float32 stereo PCM. The device
runs a small self-check on load, visible in the playback status card.
This does not attach the native engine to other applications' audio sessions.

## Why this architecture

On the Sony A80L, `dumpsys media.audio_flinger` confirmed an NXP Android
Equalizer library, an Android PCM mixer routed to HDMI ARC, and a separate
compressed direct-output route supporting E-AC3 and E-AC3-JOC. Poweramp
Equalizer was independently demonstrated to adjust YouTube and Netflix audio
using player tracking after an ADB-granted `DUMP` permission.

The Android public `Equalizer` API attaches an EQ to a **playback session**.
It cannot insert arbitrary Timbre native C++ biquads into the protected TV
audio mixer or re-encode Dolby Digital Plus. No root is required for the
supported session-based effect API, but Sony/Android firmware behavior still
determines which players and routes can be processed.

## Install and test

1. Download the debug APK from the **Android TV APK (experimental)** GitHub
   Actions build for this branch and sideload it onto the Sony A80L.
   GitHub Actions may use a different debug signing certificate for each run.
   If installing over an older debug build reports
   `INSTALL_FAILED_UPDATE_INCOMPATIBLE`, run
   `adb uninstall com.soum91.timbretv` before the new install. This erases
   the prototype's locally saved EQ curve and preset.
2. Grant diagnostics permission over ADB (one command, not a multi-line block):

   ```shell
   adb shell pm grant com.soum91.timbretv android.permission.DUMP
   ```

3. Disable Poweramp Equalizer during the test so it does not compete for the
   same Android effect engine.
4. Open **Timbre TV (Experimental)** from the Google TV apps screen and press
   **Start EQ**. A foreground notification keeps the session monitor
   active; press **Stop Timbre TV** when finished.
5. Start a YouTube or Netflix session and check the status count. Adjust a
   band by an obvious amount. If the app cannot attach to the session, the
   reason appears in status. If the session never appears, `dumpsys` may not
   be callable by the app on this firmware.
6. Independently verify the **actual incoming audio format on the Vizio
   Elevate P514a-H6** during the test. EQ audibility alone cannot prove that
   HDMI eARC is still carrying E-AC3.

## Ten-foot UI

- Native Google TV home launcher icon and 320x180 banner.
- Dark/amber remote-first tabs styled after the original Timbre tweak.
- EQ curve visualization reflecting five genuinely editable system EQ bands.
- Working Flat, Bass Boost, V-Shape, Vocal Presence, Treble Boost and
  Late Night Loudness tonal presets, plus one locally saved My curve.
- Separate Spatial, Reverb and Dynamics pages document unavailable processing.
  No dummy switch pretends to activate an unsupported audio engine.

## Native DSP integration

The `libtimbre_native.so` library is compiled for both 32-bit ARM and 64-bit
ARM, using the unchanged original DSP source and its non-Apple convolution
fallback. JNI exposes processing of app-owned stereo Float32 buffers with up
to 16 true parameterized filter bands, plus the original compressor, reverb
and spatial effects. Its filter type order is defined by `FilterType` in
`NativeDSP/TimbreDSP.hpp`.

For now, TV-wide playback processing still uses Android's fixed-band
`Equalizer` audio-session effect. The platform does not provide a supported
rootless hook that passes Netflix or YouTube PCM into the native engine,
and the native bridge does not decode or encode Dolby Digital Plus or Atmos.

## Current limitations

- Five user gain points are interpolated onto the TV's native fixed EQ bands.
  This does **not** preserve Timbre's 16 parametric filters, selectable filter
  types, center frequencies or Q values, or the compressor/spatial effects.
  A true drop-in custom DSP hook would require OEM/system audio-effect
  integration, which an unrooted Android TV does not expose to ordinary APKs.
- Protected/direct Dolby Digital Plus and Atmos tracks can bypass PCM effects.
  The app neither decodes nor manufactures a Dolby bitstream.
- Session discovery uses a Sony Android 12 `dumpsys media.audio_policy` format
  observed from the actual TV and broadcasts from cooperative players. Some
  firmware may reject `dumpsys` even after granting `DUMP`.
- When other EQ apps control a session, effects may conflict or fail to attach.
- This is an experimental debug build, not a production-quality background
  service or validated Dolby-certified signal processor.

## Build

Requires JDK 17, Android SDK 35, NDK 27.2, CMake 3.22 and Gradle 8.9:

```shell
cd android-tv
gradle :app:assembleDebug
```

APK location: `android-tv/app/build/outputs/apk/debug/app-debug.apk`.

# Timbre TV (Android 12 prototype)

An experimental Android TV controller for the system's available audio
equalizer, with per-player sessions and an opt-in global output-mix mode.
This is a new Android implementation, not a binary port of the iOS
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
Android also retains a **deprecated session-0 global mix** insertion path,
which Poweramp exposes as an experimental option. Timbre TV can now test
that route independently of session discovery, but a successfully created
effect is not proof that it processes a specific app or HDMI audio route.
It cannot insert arbitrary Timbre native C++ biquads into the protected TV
audio mixer or re-encode Dolby Digital Plus. No root is required for the
supported session-based effect API, but Sony/Android firmware behavior still
determines which players and routes can be processed.

### Soundbar-side processing

The **Soundbar** tab also provides a separate path for Vizio Elevate controls,
following the local SmartCast menu API used by the `soum91/subwave` project.
Enter the soundbar's **private IPv4 address** on the same LAN, select
**Connect / Refresh**, and browse the audio settings that its firmware
actually reports. Available EQ modes, bass/treble, surround, height, and
other settings are device-dependent. Timbre fetches valid sliders and choices
from the soundbar, performs a fresh HASHVAL read before each write, and
reads the value back afterward. Only audio settings are exposed; reset and
factory actions are not offered.

This adjusts the **soundbar itself, downstream of its HDMI decoder**. It does
not intercept, decode, modify, re-encode, or manufacture the TV's Dolby Atmos
bitstream. The TV can continue to send untouched E-AC3-JOC over ARC/eARC
when the source, subscription, TV settings, and hardware allow it. A successful
SmartCast setting readback does not prove Atmos is being received. Verify the
bar's displayed input format independently.

The local SmartCast endpoint uses a self-signed HTTPS certificate, so Timbre
relaxes certificate validation **only for the connection to the manually
entered private LAN address on port 7345 or 9000**. Use this on a trusted LAN;
this exception does not affect any other app or system HTTPS connections.
No account or app-wide cleartext traffic is enabled. The integration is
implemented but **not yet hardware-verified on the P514a-H6**.

## Install and test

1. Download the debug APK from the **Android TV APK (experimental)** GitHub
   Actions build for this branch and sideload it onto the Sony A80L.
   Starting with v0.5, GitHub Actions reuses its Android debug signing
   identity between builds through an Actions cache. Previous builds were
   signed with ephemeral keys, so **one final uninstall is required** to
   transition to v0.5 if Android reports `INSTALL_FAILED_UPDATE_INCOMPATIBLE`:

   ```shell
   adb uninstall com.soum91.timbretv
   ```

   This clears the locally saved EQ curve and preset. Once v0.5 is installed,
   later APKs signed with the cached key should install over it using
   `adb install -r app-debug.apk` or a compatible TV APK installer.
   **Limitation:** GitHub Actions caches can expire or be removed; this is
   safer than committing a private signing key to a public repository but
   is not permanent release signing. A private, backed-up signing key in
   GitHub Actions secrets is recommended for long-term updates.
2. For **per-player mode only**, grant diagnostics permission over ADB
   (one command, not a multi-line block):

   ```shell
   adb shell pm grant com.soum91.timbretv android.permission.DUMP
   ```

3. Disable Poweramp Equalizer during the test so it does not compete for the
   same Android effect engine.
4. Open **Timbre TV (Experimental)** from the Google TV apps screen. In the
   **EQ** tab, leave **Global mix: OFF** for player tracking, or switch
   **Global mix: ON** to try session 0 without a `DUMP` grant. Press
   **Start EQ**. A foreground notification keeps the session monitor
   active; press **Stop Timbre TV** when finished.
5. Start YouTube or Netflix and check **Playback Status** for the detected
   player, session ID, EQ ownership, enabled state, and hardware band readback.
   Use **A/B TEST: EQ ON / BYPASSED** while playing a familiar passage.
   A verified hardware parameter readback does not itself prove the audible
   audio route traverses the effect; listen for a clear A/B difference.
   If the session never appears, `dumpsys` may not be callable by the app.
6. Independently verify the **actual incoming audio format on the Vizio
   Elevate P514a-H6** during the test. EQ audibility alone cannot prove that
   HDMI eARC is still carrying E-AC3.

## Ten-foot UI

- Native Google TV home launcher icon and 320x180 banner.
- Dark/amber remote-first tabs styled after the original Timbre tweak.
- Add and remove up to 128 frequency control points from 20 Hz to 20 kHz.
  Additional points are **interpolated onto the fixed physical EQ bands**.
  Each point now has an adjustable Q-width control (0.3 to 10.0). Q=1.0
  reproduces the earlier log-linear curve; higher Q narrows the point's
  contribution between adjacent frequencies, and lower Q broadens it.
  These shapes are sampled onto the built-in EQ bands, **not** true hardware
  parametric filters with independently adjustable Q.
- A scrollable band editor, responsive EQ curve, and a master gain slider.
- Player detection by AudioPolicy session/UID (when DUMP works) or cooperative
  Android audio-effect broadcasts. The package label is shown when accessible.
- Master gain uses Android DynamicsProcessing input gain where supported and
  falls back to a band-level offset if that effect cannot be controlled.
- Live diagnostics showing effect ownership, enabled state, band-level readback,
  fallback/clamping information, and an audible A/B bypass toggle.
- One-button switch between individually tracked player sessions and the
  experimental Android global output mix. Modes are mutually exclusive.
- Working Flat, Bass Boost, V-Shape, Vocal Presence, Treble Boost and
  Late Night Loudness tonal presets, plus one locally saved My curve.
- Separate Spatial, Reverb and Dynamics pages document unavailable processing.
  No dummy switch pretends to activate an unsupported audio engine.
- A Soundbar tab reads and edits the Vizio's own SmartCast audio settings over
  the local network; it is independent of the TV's session EQ and HDMI codec.

## Native DSP integration

The `libtimbre_native.so` library is compiled for both 32-bit ARM and 64-bit
ARM, using the unchanged original DSP source and its non-Apple convolution
fallback. JNI exposes processing of app-owned stereo Float32 buffers with up
to 16 true parameterized filter bands, plus the original compressor, reverb
and spatial effects. Its filter type order is defined by `FilterType` in
`NativeDSP/TimbreDSP.hpp`.

For now, TV-wide playback processing still uses Android's fixed-band
`Equalizer` effect, either on a tracked playback session or (experimentally)
on the deprecated global session 0. The platform does not provide a supported
rootless hook that passes Netflix or YouTube PCM into the native engine,
and the native bridge does not decode or encode Dolby Digital Plus or Atmos.

## Current limitations

- User-defined gain points are interpolated onto the TV's native fixed EQ bands.
  Q-width editing approximates curve shape between user points but does **not**
  give hardware filters independent Q. It does not preserve Timbre's 16 true
  parametric filters, selectable filter types, compressor or spatial effects.
  A true drop-in custom DSP hook would require OEM/system audio-effect
  integration, which an unrooted Android TV does not expose to ordinary APKs.
- Protected/direct Dolby Digital Plus and Atmos tracks can bypass PCM effects.
  The app neither decodes nor manufactures a Dolby bitstream.
- Session discovery uses a Sony Android 12 `dumpsys media.audio_policy` format
  observed from the actual TV and broadcasts from cooperative players. Some
  firmware may reject `dumpsys` even after granting `DUMP`.
- Session-0 global effects are deprecated, can fail or be ignored by the TV's
  audio firmware, and may stop working after updates. Global EQ does not
  require the `DUMP` permission but also does not guarantee Dolby processing.
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

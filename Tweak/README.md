# Timbre Audio 0.6.0 (experimental)

Target: Dopamine rootless, iOS 16.x. CI builds the DEB on every push to `timbre-rootless`.
Local build on a configured Theos installation:

    cd Tweak
    make clean package THEOS_PACKAGE_SCHEME=rootless

## What's in it

**Tweak (mediaserverd / audiomxd).** Hooks `AudioUnitRender` and processes interleaved stereo
Float32 output: up to 16 parametric bands (peak, shelves, pass filters, notch, all-pass), then
compressor, crossfeed, spatial virtual speakers, stereo width/balance/mono/swap, reverb,
output gain and a peak limiter. Effect memory is allocated off the audio thread in a small
pool owned per AudioUnit. Settings reload instantly via the `com.soum91.timbreaudio.reload`
Darwin notification, with a once-per-second plist poll as fallback.

**Timbre app.** EQE-style controller:
- EQ: one gain / frequency / Q fader triplet per band, add up to 16 bands, per-band menu
  for filter type, bypass and delete. Tap any value to type it. Double-tap a fader to reset.
  Slide sideways off a fader for fine control.
- Response graph: exact biquad response; drag a dot for frequency and gain, pinch for Q.
- Spatial, Reverb and Dynamics tabs with presets, mirroring the main Timbre app.
- Presets: built-ins, saved presets (EQ + effects), Equalizer APO / AutoEq import from the
  clipboard and export to the clipboard.

## Hooking and diagnostics

Same hook point as EQE: `AudioUnitRender` inside mediaserverd (audiomxd on newer iOS). Only the
outermost render call on each thread (the final mix) is processed; nested mixer-input renders are
passed through. Interleaved and planar stereo, Float32 and Int16, are supported.

Settings are written to `/var/jb/var/mobile/Library/Preferences/com.soum91.timbreaudio.plist`
(readable from the sandboxed daemon) with a legacy copy in `/var/mobile/Library/Preferences`.
The tweak publishes live status through Darwin notification state
(`com.soum91.timbreaudio.status.<process>.*`), shown in the app's Status page (gear icon).

The app is unsandboxed (platform-application, no-sandbox) and ships `timbrectl`, a setuid-root
helper at `/var/jb/usr/libexec/timbrectl` that only accepts `restart-audio` and `fix-prefs`.
Installing the package restarts mediaserverd so the tweak loads immediately.

## Caution

Still not device-validated. AudioUnitRender may not cover every playback route, and only
interleaved stereo Float32 is processed (effects need 96 kHz or lower). Spatial is an
interaural delay / head-shadow approximation, not a measured HRTF. If audio services fail,
remove the tweak from jailbreak safe mode.

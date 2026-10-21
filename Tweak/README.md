# Timbre Audio 0.7.0 (experimental)

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

## 0.7.0 additions

**Immersive spatial.** Stereo is upmixed to nine virtual speakers (centre, front pair, sides,
rears, two front heights) and rendered binaurally with the MIT KEMAR compact diffused HRTF set
(Bill Gardner and Keith Martin, MIT Media Lab; packaged by mit-hrtf-lib, MIT licence), using
vDSP convolution. Tables cover 44.1, 48, 88.2 and 96 kHz. This is not Dolby Atmos decoding.

**Output-device profiles.** The tweak also loads into SpringBoard, where it only records the
current output route to `com.soum91.timbreaudio.route.plist` under the jailbreak root. The audio
daemon resolves a rule per output (device UID first, then type: speaker, wired, Bluetooth,
AirPlay, CarPlay, USB/HDMI): current EQ, Timbre off, or a stored preset/snapshot.

**AirPlay picker** in the controller.

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

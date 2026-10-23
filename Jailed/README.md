# App-local Timbre native audio test

Test 1 ports the existing NativeDSP engine into a sideloaded application without Substrate, inline instruction patching, private entitlements, jailbreak paths, DRM hooks, audio extraction or a system daemon.

It rebinds three imported AudioToolbox functions only in `dmengine.framework`: callback registration, graph start and graph disposal. The mixer callback first calls the original producer, then processes supported stereo PCM buffers in place. No assumption is made that every Amazon playback route uses this graph. The app starts with DSP bypassed and exposes callback counts, processed frame counts and an attenuation test.

The first build has parametric EQ (up to 64 bands), preamp, compressor, crossfeed, immersive spatial, stereo width, reverb and a limiter. Head tracking, casting, profiles and preset import are not ported in this test. Effects support rates up to 96 kHz; EQ supports stereo Float32/Int16 from 8 to 192 kHz. Unsupported formats pass through.

Build with the `native-injection.yml` workflow on `amazon-native-eq-test`. Only Timbre source and its compiled library go to GitHub. The host IPA is packaged locally and must be signed with the user's sideloading service before installation. No Amazon executable is committed here.

The callback adapter is experimental and has not been device-validated. Play a music track, open Timbre, enable DSP and select the -12 dB test. Compare enabled with bypass. A registration or callback count alone does not establish processing of the main music stream. DSP frame counts plus audible attenuation are required to confirm that route.

Third-party symbol rebinding code is from facebook/fishhook; its BSD license remains in fishhook.c and fishhook.h.

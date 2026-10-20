# Timbre

A browser with an EQE-style audio engine bolted on. Log into your streaming sites and run everything they play through a parametric EQ, spatial, reverb, crossfeed, compressor and limiter.

## What's in it

**EQ.** Unlimited parametric bands (peak, low/high shelf, low/high pass, band pass, notch, all pass), each with its own frequency, gain and Q. Drag the nodes on the graph, pinch to change Q, double-tap to add a band. Preamp with auto-headroom, plus a live spectrum behind the curve.

**Effects.** HRTF spatial (left/right become virtual speakers with angle, distance and elevation), reverb (built-in room generator or load your own WAV/AIFF impulse response), Bauer-style crossfeed, stereo width/balance/mono/swap, compressor, output gain and a limiter.

**Presets.** Save with or without effects, AutoEq search covering thousands of headphones, and import of EqualizerAPO / Peace parametric configs and Winamp `.eqf` libraries. Export goes out as EqualizerAPO text.

**Browser.** Logins persist, popups for sign-in flows, desktop-site toggle, a real Safari user agent so Google sign-in works, background playback (the page is told it's always visible), and app deep links are blocked so Amazon and Spotify can't bounce you to their apps.

## How it works

`Timbre/Engine/engine.js` gets injected into every frame at document start. It hooks media elements as they start playing, routes them through `createMediaElementSource` into a Web Audio graph, and takes live config from the app.

```
source → preamp → bands… → compressor → crossfeed → width → spatial → reverb → output → limiter → out
```

Shelves use `IIRFilterNode` with exact RBJ coefficients (WebKit's biquad shelves ignore Q) behind a crossfade so edits don't click. The graph curve in the app uses the same math, verified against WebKit's `getFrequencyResponse`.

## Limits

- **DRM streams can't be EQ'd.** Spotify, Amazon Music, Apple Music and Tidal web players decrypt in a protected path that Web Audio can't read. Timbre detects encrypted media and leaves it alone. If a stream goes silent anyway, the banner offers to turn Timbre off for that site.
- **Cross-origin files** only get EQ'd if the server allows CORS. Timbre probes and reloads in CORS mode when it can, and otherwise leaves the stream untouched.
- Works well on YouTube Music, YouTube, Deezer and most MSE-based players.

## Build

GitHub Actions builds an unsigned IPA on every push to `main` and attaches it to the `latest` release. Sideload it with TrollStore, AltStore, SideStore or Sideloadly.

Local: `brew install xcodegen && xcodegen generate && open Timbre.xcodeproj`

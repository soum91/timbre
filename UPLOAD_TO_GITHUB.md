# Upload Timbre rootless work to GitHub

Target repository: https://github.com/soum91/timbre

## Browser upload (desktop recommended)

1. Extract this ZIP on your computer.
2. Open https://github.com/soum91/timbre and create a branch named `timbre-rootless` from `main` using the branch selector.
3. Open https://github.com/soum91/timbre/upload/timbre-rootless .
4. Drag the *contents* of `timbre-main` into the upload area (not the ZIP itself). GitHub should preserve subfolders. Existing files may show as replacements; this archive is based on the provided main snapshot.
5. Commit directly to `timbre-rootless`.
6. Open a pull request to `main` only after reviewing the changes.

Alternatively, on a computer with git installed:

    git clone https://github.com/soum91/timbre.git
    cd timbre
    git switch -c timbre-rootless
    # Copy the extracted timbre-main directory's contents into this checkout.
    git add NativeDSP Tweak .github/workflows/native-dsp.yml
    git commit -m 'Add experimental rootless audio tweak scaffold and native DSP tests'
    git push -u origin timbre-rootless

## Current limitations

- Native DSP is testable on Linux and macOS, but the iOS tweak is not compiled or validated.
- `Tweak/Tweak.mm` hooks AudioUnitRender experimentally but intentionally leaves DSP disabled.
- The app UI has not yet been converted into a tweak controller.
- A working `.deb` is not included. Installing a hook into mediaserverd can destabilize audio or cause daemon crashes; do not install until validated.

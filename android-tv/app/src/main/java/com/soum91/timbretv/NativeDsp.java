package com.soum91.timbretv;

/** JNI adapter for Timbre's original, mostly portable C++ engine. */
final class NativeDsp {
    private static final boolean READY;

    static {
        boolean ready;
        try {
            System.loadLibrary("timbre_native");
            ready = runSelfTest();
        } catch (LinkageError | RuntimeException error) {
            ready = false;
        }
        READY = ready;
    }

    private NativeDsp() {}

    static boolean isReady() { return READY; }

    private static native boolean runSelfTest();

    /**
     * Applies the original DSP to app-owned Float32 stereo PCM.
     * Filter types follow NativeDSP/TimbreDSP.hpp (Peaking = 0 through AllPass = 7).
     * System audio sessions and Dolby passthrough do not expose their PCM here.
     */
    static native float[] processPcm(float[] stereoPcm, int sampleRate,
            float[] frequencies, float[] gains, float[] q, int[] filterTypes,
            boolean compressor, boolean reverb, boolean spatial);
}

package com.soum91.timbretv;

import android.content.Context;
import android.content.SharedPreferences;

final class EqSettings {
    static final float[] FREQUENCIES = {60, 250, 1000, 4000, 12000};
    private static final String PREFS = "timbre_tv";
    static final String STATUS = "status";
    static final String ENABLED = "enabled";
    // Android's deprecated global output-mix session (0). Opt-in only.
    static final String GLOBAL_MIX = "global_mix";

    private EqSettings() {}

    static SharedPreferences preferences(Context context) {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    static int[] readGains(Context context) {
        SharedPreferences preferences = preferences(context);
        int[] values = new int[FREQUENCIES.length];
        for (int i = 0; i < values.length; i++) {
            values[i] = preferences.getInt("band_" + i, 0);
        }
        return values;
    }

    static void saveGain(Context context, int band, int decibels) {
        preferences(context).edit().putInt("band_" + band, decibels).apply();
    }

    static void saveGains(Context context, int[] gains) {
        SharedPreferences.Editor editor = preferences(context).edit();
        for (int i = 0; i < FREQUENCIES.length; i++) {
            editor.putInt("band_" + i, Math.max(-12, Math.min(12, gains[i])));
        }
        editor.apply();
    }

    static void saveCustomPreset(Context context) {
        int[] gains = readGains(context);
        SharedPreferences.Editor editor = preferences(context).edit().putBoolean("has_custom", true);
        for (int i = 0; i < gains.length; i++) editor.putInt("custom_band_" + i, gains[i]);
        editor.apply();
    }

    static int[] readCustomPreset(Context context) {
        if (!preferences(context).getBoolean("has_custom", false)) return null;
        int[] gains = new int[FREQUENCIES.length];
        for (int i = 0; i < gains.length; i++) {
            gains[i] = preferences(context).getInt("custom_band_" + i, 0);
        }
        return gains;
    }

    // Interpolate the user curve onto the device's real, fixed-band equalizer.
    // Android's public Equalizer API cannot implement arbitrary Q/biquad filters.
    static float gainAt(float frequency, int[] gains) {
        if (frequency <= FREQUENCIES[0]) return gains[0];
        int last = FREQUENCIES.length - 1;
        if (frequency >= FREQUENCIES[last]) return gains[last];
        for (int i = 0; i < last; i++) {
            if (frequency <= FREQUENCIES[i + 1]) {
                double a = Math.log(FREQUENCIES[i]);
                double b = Math.log(FREQUENCIES[i + 1]);
                double t = (Math.log(frequency) - a) / (b - a);
                return (float) (gains[i] + t * (gains[i + 1] - gains[i]));
            }
        }
        return 0;
    }
}

package com.soum91.timbretv;

import android.content.Context;
import android.content.SharedPreferences;

final class EqSettings {
    static final float[] FREQUENCIES = {60, 250, 1000, 4000, 12000};
    private static final String PREFS = "timbre_tv";
    static final String STATUS = "status";
    static final String ENABLED = "enabled";

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

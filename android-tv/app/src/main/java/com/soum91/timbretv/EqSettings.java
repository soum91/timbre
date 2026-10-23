package com.soum91.timbretv;

import android.content.Context;
import android.content.SharedPreferences;
import org.json.JSONArray;
import org.json.JSONException;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;

/** Arbitrary EQ points are interpolated onto Android's real hardware bands. */
final class EqSettings {
    static final float[] DEFAULT_FREQUENCIES = {60, 250, 1000, 4000, 12000};
    private static final String PREFS = "timbre_tv";
    private static final String CURVE = "curve_v2";
    private static final String CUSTOM_CURVE = "custom_curve_v2";
    static final String STATUS = "status";
    static final String ENABLED = "enabled";
    static final String GLOBAL_MIX = "global_mix";
    static final String GLOBAL_GAIN = "global_gain_db";
    static final String BYPASS = "bypass";
    static final int MIN_DB = -12, MAX_DB = 12, MAX_POINTS = 128;

    static final class Curve {
        final float[] frequencies;
        final int[] gains;
        Curve(float[] frequencies, int[] gains) {
            this.frequencies = frequencies.clone();
            this.gains = gains.clone();
        }
    }

    private EqSettings() {}

    static SharedPreferences preferences(Context context) {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    static Curve readCurve(Context context) {
        SharedPreferences prefs = preferences(context);
        Curve restored = decode(prefs.getString(CURVE, null));
        if (restored != null) return restored;
        int[] gains = new int[DEFAULT_FREQUENCIES.length];
        for (int i = 0; i < gains.length; i++) gains[i] = clamp(prefs.getInt("band_" + i, 0));
        return new Curve(DEFAULT_FREQUENCIES, gains);
    }

    static void saveCurve(Context context, Curve curve) {
        preferences(context).edit().putString(CURVE, encode(curve)).apply();
    }

    static void saveGain(Context context, int band, int decibels) {
        Curve curve = readCurve(context);
        if (band < 0 || band >= curve.gains.length) return;
        curve.gains[band] = clamp(decibels);
        saveCurve(context, curve);
    }

    static boolean addBand(Context context, float frequency) {
        if (!Float.isFinite(frequency) || frequency < 20f || frequency > 20000f) return false;
        Curve current = readCurve(context);
        if (current.frequencies.length >= MAX_POINTS) return false;
        for (float f : current.frequencies) if (Math.abs(frequency - f) < 0.5f) return false;
        float[] freqs = new float[current.frequencies.length + 1];
        int[] gains = new int[freqs.length];
        int next = 0;
        boolean inserted = false;
        for (int i = 0; i < current.frequencies.length; i++) {
            if (!inserted && frequency < current.frequencies[i]) {
                freqs[next] = frequency;
                gains[next++] = Math.round(gainAt(frequency, current));
                inserted = true;
            }
            freqs[next] = current.frequencies[i];
            gains[next++] = current.gains[i];
        }
        if (!inserted) {
            freqs[next] = frequency;
            gains[next] = Math.round(gainAt(frequency, current));
        }
        saveCurve(context, new Curve(freqs, gains));
        return true;
    }

    static boolean removeBand(Context context, int index) {
        Curve old = readCurve(context);
        if (old.frequencies.length <= 2 || index < 0 || index >= old.frequencies.length) return false;
        float[] freqs = new float[old.frequencies.length - 1];
        int[] gains = new int[freqs.length];
        for (int i = 0, j = 0; i < old.frequencies.length; i++) {
            if (i == index) continue;
            freqs[j] = old.frequencies[i];
            gains[j++] = old.gains[i];
        }
        saveCurve(context, new Curve(freqs, gains));
        return true;
    }

    static void applyPreset(Context context, int[] defaultGains) {
        if (defaultGains.length != DEFAULT_FREQUENCIES.length) return;
        Curve existing = readCurve(context);
        Curve preset = new Curve(DEFAULT_FREQUENCIES, defaultGains);
        int[] mapped = new int[existing.frequencies.length];
        for (int i = 0; i < mapped.length; i++) {
            mapped[i] = clamp(Math.round(gainAt(existing.frequencies[i], preset)));
        }
        saveCurve(context, new Curve(existing.frequencies, mapped));
    }

    static void saveCustomPreset(Context context) {
        preferences(context).edit().putString(CUSTOM_CURVE, encode(readCurve(context))).apply();
    }

    static Curve readCustomPreset(Context context) {
        SharedPreferences prefs = preferences(context);
        Curve curve = decode(prefs.getString(CUSTOM_CURVE, null));
        if (curve != null) return curve;
        if (!prefs.getBoolean("has_custom", false)) return null;
        int[] gains = new int[DEFAULT_FREQUENCIES.length];
        for (int i = 0; i < gains.length; i++) {
            gains[i] = clamp(prefs.getInt("custom_band_" + i, 0));
        }
        return new Curve(DEFAULT_FREQUENCIES, gains);
    }

    static float gainAt(float frequency, Curve curve) {
        if (frequency <= curve.frequencies[0]) return curve.gains[0];
        int last = curve.frequencies.length - 1;
        if (frequency >= curve.frequencies[last]) return curve.gains[last];
        for (int i = 0; i < last; i++) {
            if (frequency <= curve.frequencies[i + 1]) {
                double a = Math.log(curve.frequencies[i]);
                double b = Math.log(curve.frequencies[i + 1]);
                double t = (Math.log(frequency) - a) / (b - a);
                return (float) (curve.gains[i] + t * (curve.gains[i + 1] - curve.gains[i]));
            }
        }
        return 0;
    }

    private static int clamp(int gain) { return Math.max(MIN_DB, Math.min(MAX_DB, gain)); }

    private static String encode(Curve curve) {
        JSONArray array = new JSONArray();
        for (int i = 0; i < curve.frequencies.length; i++) {
            JSONArray point = new JSONArray();
            point.put(curve.frequencies[i]);
            point.put(clamp(curve.gains[i]));
            array.put(point);
        }
        return array.toString();
    }

    private static Curve decode(String json) {
        if (json == null) return null;
        try {
            JSONArray array = new JSONArray(json);
            if (array.length() < 2 || array.length() > MAX_POINTS) return null;
            List<float[]> points = new ArrayList<>();
            for (int i = 0; i < array.length(); i++) {
                JSONArray point = array.getJSONArray(i);
                float frequency = (float) point.getDouble(0);
                if (!Float.isFinite(frequency) || frequency < 20 || frequency > 20000) return null;
                points.add(new float[]{frequency, clamp(point.getInt(1))});
            }
            points.sort(Comparator.comparingDouble(p -> p[0]));
            float[] freqs = new float[points.size()];
            int[] gains = new int[points.size()];
            for (int i = 0; i < points.size(); i++) {
                freqs[i] = points.get(i)[0];
                gains[i] = (int) points.get(i)[1];
                if (i > 0 && freqs[i] - freqs[i - 1] < 0.5f) return null;
            }
            return new Curve(freqs, gains);
        } catch (JSONException e) {
            return null;
        }
    }
}

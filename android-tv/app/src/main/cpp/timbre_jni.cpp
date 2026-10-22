#include <jni.h>
#include "TimbreDSP.hpp"

#include <algorithm>
#include <cmath>
#include <exception>
#include <vector>

namespace {
void argumentError(JNIEnv* env, const char* message) {
    jclass type = env->FindClass("java/lang/IllegalArgumentException");
    if (type) env->ThrowNew(type, message);
}

void stateError(JNIEnv* env, const char* message) {
    jclass type = env->FindClass("java/lang/IllegalStateException");
    if (type) env->ThrowNew(type, message);
}
}

// Small device-side check that the real Timbre C++ engine is linked and works.
extern "C" JNIEXPORT jboolean JNICALL
Java_com_soum91_timbretv_NativeDsp_runSelfTest(JNIEnv*, jclass) {
    try {
        timbre::StereoEQ eq(48000);
        eq.configure({timbre::Band{true, timbre::FilterType::Peaking, 1000, 6, 1}}, 0);
        float impulse[16] = {1};
        eq.process(impulse, 8);
        if (!std::isfinite(impulse[0]) || impulse[0] == 1.0f) return JNI_FALSE;

        timbre::Effects effects;
        if (!effects.prepare(48000)) return JNI_FALSE;
        timbre::EffectsParams params;
        params.comp.on = true;
        params.reverb.on = true;
        effects.configure(params);
        effects.process(impulse, 8);
        for (float sample : impulse) if (!std::isfinite(sample)) return JNI_FALSE;
        return JNI_TRUE;
    } catch (...) {
        return JNI_FALSE;
    }
}

// Offline processing boundary for an app-owned interleaved stereo PCM buffer.
// This is NOT a system-wide Android mixer hook and cannot edit Dolby passthrough.
extern "C" JNIEXPORT jfloatArray JNICALL
Java_com_soum91_timbretv_NativeDsp_processPcm(
        JNIEnv* env, jclass, jfloatArray input, jint sampleRate,
        jfloatArray frequencies, jfloatArray gains, jfloatArray qualities,
        jintArray types, jboolean compressor, jboolean reverb, jboolean spatial) {
    if (!input || !frequencies || !gains || !qualities || !types) {
        argumentError(env, "PCM and band arrays must not be null");
        return nullptr;
    }
    const jsize framesTimesTwo = env->GetArrayLength(input);
    const jsize n = env->GetArrayLength(frequencies);
    if (sampleRate < 8000 || sampleRate > 96000 || framesTimesTwo <= 0
            || (framesTimesTwo % 2) != 0 || framesTimesTwo > 4000000
            || n > 16 || env->GetArrayLength(gains) != n
            || env->GetArrayLength(qualities) != n || env->GetArrayLength(types) != n) {
        argumentError(env, "Unsupported PCM format or filter array lengths");
        return nullptr;
    }

    std::vector<float> pcm(framesTimesTwo);
    std::vector<float> hz(n), db(n), q(n);
    std::vector<jint> filterTypes(n);
    env->GetFloatArrayRegion(input, 0, framesTimesTwo, pcm.data());
    if (n > 0) {
        env->GetFloatArrayRegion(frequencies, 0, n, hz.data());
        env->GetFloatArrayRegion(gains, 0, n, db.data());
        env->GetFloatArrayRegion(qualities, 0, n, q.data());
        env->GetIntArrayRegion(types, 0, n, filterTypes.data());
    }
    if (env->ExceptionCheck()) return nullptr;

    std::vector<timbre::Band> bands;
    bands.reserve(n);
    for (jsize i = 0; i < n; ++i) {
        if (!std::isfinite(hz[i]) || !std::isfinite(db[i]) || !std::isfinite(q[i])
                || hz[i] <= 0 || hz[i] >= sampleRate / 2.f
                || q[i] <= 0 || filterTypes[i] < 0 || filterTypes[i] > 7) {
            argumentError(env, "Invalid band frequency, Q, gain or filter type");
            return nullptr;
        }
        bands.push_back(timbre::Band{true,
                static_cast<timbre::FilterType>(filterTypes[i]), hz[i], db[i], q[i]});
    }

    try {
        timbre::StereoEQ eq(sampleRate);
        eq.configure(bands, 0);
        eq.process(pcm.data(), pcm.size() / 2);

        timbre::Effects effects;
        if (!effects.prepare(sampleRate)) {
            stateError(env, "Native effects cannot prepare this sample rate");
            return nullptr;
        }
        timbre::EffectsParams config;
        config.comp.on = compressor == JNI_TRUE;
        config.reverb.on = reverb == JNI_TRUE;
        config.spatial.on = spatial == JNI_TRUE;
        effects.configure(config);
        effects.process(pcm.data(), pcm.size() / 2);

        jfloatArray output = env->NewFloatArray(framesTimesTwo);
        if (!output) return nullptr;
        env->SetFloatArrayRegion(output, 0, framesTimesTwo, pcm.data());
        return output;
    } catch (const std::exception& e) {
        stateError(env, e.what());
        return nullptr;
    } catch (...) {
        stateError(env, "Unexpected native DSP failure");
        return nullptr;
    }
}

package com.soum91.timbretv;

import android.Manifest;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.media.audiofx.AudioEffect;
import android.media.audiofx.DynamicsProcessing;
import android.media.audiofx.Equalizer;
import android.os.IBinder;

import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

public final class TimbreService extends Service {
    static final String START = "com.soum91.timbretv.START";
    static final String STOP = "com.soum91.timbretv.STOP";
    static final String APPLY = "com.soum91.timbretv.APPLY";
    private static final String CHANNEL = "timbre_tv_audio";
    private final ScheduledExecutorService executor = Executors.newSingleThreadScheduledExecutor();
    private final Map<Integer, Equalizer> effects = new HashMap<>();
    private final Map<Integer, DynamicsProcessing> gainEffects = new HashMap<>();
    private final Set<Integer> announcedSessions = ConcurrentHashMap.newKeySet();
    private final Map<Integer, String> announcedPlayers = new ConcurrentHashMap<>();
    private Equalizer globalEffect;
    private DynamicsProcessing globalGainEffect;
    private volatile boolean running;

    private final BroadcastReceiver sessions = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            int id = intent.getIntExtra(AudioEffect.EXTRA_AUDIO_SESSION, 0);
            if (id <= 0) return;
            if (AudioEffect.ACTION_OPEN_AUDIO_EFFECT_CONTROL_SESSION.equals(intent.getAction())) {
                announcedSessions.add(id);
                String player = intent.getStringExtra(AudioEffect.EXTRA_PACKAGE_NAME);
                if (player != null && !player.isEmpty()) announcedPlayers.put(id, player);
            } else if (AudioEffect.ACTION_CLOSE_AUDIO_EFFECT_CONTROL_SESSION.equals(intent.getAction())) {
                announcedSessions.remove(id);
                announcedPlayers.remove(id);
            }
            executor.execute(TimbreService.this::reconcile);
        }
    };

    @Override public void onCreate() {
        super.onCreate();
        NotificationChannel channel = new NotificationChannel(CHANNEL, "Timbre TV audio",
                NotificationManager.IMPORTANCE_LOW);
        getSystemService(NotificationManager.class).createNotificationChannel(channel);
        IntentFilter filter = new IntentFilter();
        filter.addAction(AudioEffect.ACTION_OPEN_AUDIO_EFFECT_CONTROL_SESSION);
        filter.addAction(AudioEffect.ACTION_CLOSE_AUDIO_EFFECT_CONTROL_SESSION);
        registerReceiver(sessions, filter);
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent == null ? START : intent.getAction();
        if (STOP.equals(action)) {
            running = false;
            EqSettings.preferences(this).edit().putBoolean(EqSettings.ENABLED, false)
                    .putString(EqSettings.STATUS, "Stopped").apply();
            stopForeground(true);
            stopSelf();
            return START_NOT_STICKY;
        }
        if (!running) {
            running = true;
            foreground();
            EqSettings.preferences(this).edit().putBoolean(EqSettings.ENABLED, true).apply();
            executor.scheduleWithFixedDelay(this::reconcile, 0, 4, TimeUnit.SECONDS);
        } else if (APPLY.equals(action)) {
            executor.execute(this::reconcile);
        }
        return START_STICKY;
    }

    private void foreground() {
        PendingIntent content = PendingIntent.getActivity(this, 0,
                new Intent(this, MainActivity.class), PendingIntent.FLAG_IMMUTABLE);
        Notification notification = new Notification.Builder(this, CHANNEL)
                .setContentTitle("Timbre TV")
                .setContentText("Equalizing accessible Android audio")
                .setSmallIcon(android.R.drawable.ic_media_play)
                .setContentIntent(content)
                .setOngoing(true)
                .build();
        startForeground(41, notification);
    }

    private SessionMonitor.Result scanSessions() {
        if (checkSelfPermission(Manifest.permission.DUMP) == PackageManager.PERMISSION_GRANTED) {
            return SessionMonitor.scan();
        }
        SessionMonitor.Result result = new SessionMonitor.Result();
        result.error = "ADB DUMP not granted: adb shell pm grant com.soum91.timbretv android.permission.DUMP";
        return result;
    }

    private void reconcile() {
        if (!running) return;
        EqSettings.Curve curve = EqSettings.readCurve(this);
        boolean global = EqSettings.preferences(this).getBoolean(EqSettings.GLOBAL_MIX, false);
        boolean bypass = EqSettings.preferences(this).getBoolean(EqSettings.BYPASS, false);
        int masterGain = EqSettings.preferences(this).getInt(EqSettings.GLOBAL_GAIN, 0);
        SessionMonitor.Result scan = scanSessions();
        Set<Integer> active = new HashSet<>(scan.sessions);
        active.addAll(announcedSessions);
        StringBuilder status = new StringBuilder();
        status.append(bypass ? "A/B TEST: BYPASS ON (effects disabled)"
                : "A/B TEST: EQ ON (effects requested)");
        status.append("\nPlayer detected: ").append(active.size())
                .append("; control points: ").append(curve.frequencies.length);
        status.append("\nBand Q: approximate curve shaping only (hardware Q fixed)");
        if (scan.error != null) status.append("\n").append(scan.error);

        synchronized (effects) {
            if (global) {
                releaseIndividual();
                status.append("\nRouting: experimental global output mix (session 0)");
                try {
                    if (globalEffect == null) globalEffect = new Equalizer(1000, 0);
                    String gainMode = setupGain(0, masterGain, bypass, true);
                    status.append("\nGlobal EQ: ").append(configureEq(globalEffect, curve,
                            gainMode.startsWith("EQ offset") ? masterGain : 0, bypass));
                    status.append("; gain: ").append(gainMode);
                } catch (RuntimeException e) {
                    if (globalEffect != null) {
                        globalEffect.release();
                        globalEffect = null;
                    }
                    releaseGlobalGain();
                    status.append("\nGlobal output EQ unavailable: ")
                            .append(e.getClass().getSimpleName());
                }
            } else {
                releaseGlobal();
                for (Integer session : new HashSet<>(effects.keySet())) {
                    if (!active.contains(session)) {
                        effects.remove(session).release();
                        DynamicsProcessing gain = gainEffects.remove(session);
                        if (gain != null) gain.release();
                    }
                }
                for (Integer session : new HashSet<>(gainEffects.keySet())) {
                    if (!active.contains(session)) gainEffects.remove(session).release();
                }
                status.append("\nRouting: per-player audio sessions");
                int displayed = 0;
                for (Integer session : active) {
                    if (++displayed > 8) continue;
                    status.append("\n").append(playerLabel(session, scan))
                            .append(" [session ").append(session).append("]: ");
                    try {
                        Equalizer effect = effects.get(session);
                        if (effect == null) {
                            effect = new Equalizer(1000, session);
                            effects.put(session, effect);
                        }
                        String gainMode = setupGain(session, masterGain, bypass, false);
                        status.append(configureEq(effect, curve,
                                gainMode.startsWith("EQ offset") ? masterGain : 0, bypass));
                        status.append("; gain: ").append(gainMode);
                    } catch (RuntimeException e) {
                        Equalizer failed = effects.remove(session);
                        if (failed != null) failed.release();
                        DynamicsProcessing gain = gainEffects.remove(session);
                        if (gain != null) gain.release();
                        status.append("effect failed: ").append(e.getClass().getSimpleName());
                    }
                }
                if (displayed > 8) status.append("\n+").append(displayed - 8)
                        .append(" additional sessions omitted from status");
                if (active.isEmpty()) status.append("\nNo accessible player currently detected. "
                        + "Start playback and check ADB DUMP permission.");
            }
            status.append("\nReadback means Android accepted effect parameters; it DOES NOT "
                    + "confirm audible processing. HDMI Dolby passthrough, DRM, or offload can bypass EQ. "
                    + "Use A/B bypass while listening to confirm.");
            EqSettings.preferences(this).edit().putString(EqSettings.STATUS, status.toString()).apply();
        }
    }

    private String playerLabel(int session, SessionMonitor.Result scan) {
        String pkg = announcedPlayers.get(session);
        Integer uid = scan.uidBySession.get(session);
        if (pkg == null && uid != null) {
            String[] packages = getPackageManager().getPackagesForUid(uid);
            if (packages != null && packages.length > 0) pkg = packages[0];
        }
        if (pkg != null) {
            try {
                ApplicationInfo app = getPackageManager().getApplicationInfo(pkg, 0);
                String label = getPackageManager().getApplicationLabel(app).toString();
                return label + " (" + pkg + ")";
            } catch (PackageManager.NameNotFoundException | SecurityException ignored) {
                return pkg;
            }
        }
        return uid == null ? "Unknown player" : "UID " + uid + " (package unavailable)";
    }

    private String configureEq(Equalizer effect, EqSettings.Curve curve, int gainOffset,
                               boolean bypass) {
        boolean control = effect.hasControl();
        if (!control) return "EQ control NO (another app may own it)";
        short[] limits = effect.getBandLevelRange();
        int verified = 0;
        int bands = effect.getNumberOfBands();
        int clipped = 0;
        for (short band = 0; band < bands; band++) {
            float center = effect.getCenterFreq(band) / 1000.0f;
            int target = Math.round((EqSettings.gainAt(center, curve) + gainOffset) * 100f);
            int actual = Math.max(limits[0], Math.min(limits[1], target));
            if (target != actual) clipped++;
            effect.setBandLevel(band, (short) actual);
            if (effect.getBandLevel(band) == (short) actual) verified++;
        }
        effect.setEnabled(!bypass);
        return "EQ control YES, enabled " + effect.getEnabled()
                + ", hardware band readback " + verified + "/" + bands
                + (clipped > 0 ? ", clamped bands " + clipped : "");
    }

    /**
     * Prefer a genuine input-gain stage. If Android won't create/control it,
     * use an explicitly reported, less-accurate offset on hardware EQ bands.
     */
    private String setupGain(int session, int gainDb, boolean bypass, boolean global) {
        if (gainDb == 0 || bypass) {
            if (global) releaseGlobalGain();
            else {
                DynamicsProcessing old = gainEffects.remove(session);
                if (old != null) old.release();
            }
            return gainDb == 0 ? "0 dB (neutral)" : "disabled for A/B test";
        }
        DynamicsProcessing gain = global ? globalGainEffect : gainEffects.get(session);
        try {
            if (gain == null) {
                gain = new DynamicsProcessing(session);
                if (global) globalGainEffect = gain;
                else gainEffects.put(session, gain);
            }
            if (!gain.hasControl()) throw new IllegalStateException("No DSP control");
            gain.setInputGainAllChannelsTo(gainDb);
            gain.setEnabled(true);
            float readback = gain.getInputGainByChannelIndex(0);
            if (!gain.getEnabled() || Math.abs(readback - gainDb) > 0.1f) {
                throw new IllegalStateException("Input gain readback failed");
            }
            return "DynamicsProcessing " + gainDb + " dB (readback OK)";
        } catch (RuntimeException e) {
            if (global) releaseGlobalGain();
            else {
                DynamicsProcessing failed = gainEffects.remove(session);
                if (failed != null) failed.release();
            }
            return "EQ offset " + gainDb + " dB (DSP unavailable: "
                    + e.getClass().getSimpleName() + ")";
        }
    }

    private void releaseIndividual() {
        for (Equalizer effect : effects.values()) effect.release();
        effects.clear();
        for (DynamicsProcessing effect : gainEffects.values()) effect.release();
        gainEffects.clear();
    }

    private void releaseGlobalGain() {
        if (globalGainEffect != null) {
            globalGainEffect.release();
            globalGainEffect = null;
        }
    }

    private void releaseGlobal() {
        if (globalEffect != null) {
            globalEffect.release();
            globalEffect = null;
        }
        releaseGlobalGain();
    }

    @Override public void onDestroy() {
        running = false;
        EqSettings.preferences(this).edit().putBoolean(EqSettings.ENABLED, false).apply();
        unregisterReceiver(sessions);
        executor.shutdownNow();
        synchronized (effects) {
            releaseIndividual();
            releaseGlobal();
        }
        super.onDestroy();
    }

    @Override public IBinder onBind(Intent intent) { return null; }
}

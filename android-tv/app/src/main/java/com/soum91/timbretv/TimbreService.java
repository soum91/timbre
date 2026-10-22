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
import android.content.pm.PackageManager;
import android.media.audiofx.AudioEffect;
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
    private Equalizer globalEffect;
    private final Set<Integer> announcedSessions = ConcurrentHashMap.newKeySet();
    private volatile boolean running;

    private final BroadcastReceiver sessions = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            int id = intent.getIntExtra(AudioEffect.EXTRA_AUDIO_SESSION, 0);
            if (id <= 0) return;
            if (AudioEffect.ACTION_OPEN_AUDIO_EFFECT_CONTROL_SESSION.equals(intent.getAction())) {
                announcedSessions.add(id);
            } else if (AudioEffect.ACTION_CLOSE_AUDIO_EFFECT_CONTROL_SESSION.equals(intent.getAction())) {
                announcedSessions.remove(id);
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

    private void reconcile() {
        if (!running) return;
        int[] gains = EqSettings.readGains(this);
        boolean global = EqSettings.preferences(this).getBoolean(EqSettings.GLOBAL_MIX, false);
        if (global) {
            // Session 0 is Android's deprecated, firmware-dependent output-mix path.
            // Do not stack a second EQ on each individual player while it is selected.
            synchronized (effects) {
                for (Equalizer effect : effects.values()) effect.release();
                effects.clear();
                String status;
                try {
                    if (globalEffect == null) globalEffect = new Equalizer(1000, 0);
                    if (!globalEffect.hasControl()) {
                        status = "GLOBAL MIX (session 0): effect created, but Timbre has no control. "
                                + "Turn off other equalizers and retry.";
                    } else {
                        applyGains(globalEffect, gains);
                        globalEffect.setEnabled(true);
                        status = "GLOBAL MIX (session 0): EQ created; control: yes; "
                                + "enabled: " + globalEffect.getEnabled()
                                + "; hardware bands: " + globalEffect.getNumberOfBands();
                    }
                } catch (RuntimeException e) {
                    if (globalEffect != null) {
                        globalEffect.release();
                        globalEffect = null;
                    }
                    status = "GLOBAL MIX (session 0): unavailable ("
                            + e.getClass().getSimpleName() + "). "
                            + "Try per-player session EQ instead.";
                }
                status += "\nEngine status does not prove audible processing. "
                        + "Dolby passthrough may bypass Android EQ.";
                EqSettings.preferences(this).edit().putString(EqSettings.STATUS, status).apply();
            }
            return;
        }

        SessionMonitor.Result scan;
        if (checkSelfPermission(Manifest.permission.DUMP) == PackageManager.PERMISSION_GRANTED) {
            scan = SessionMonitor.scan();
        } else {
            scan = new SessionMonitor.Result();
            scan.error = "ADB permission required: pm grant com.soum91.timbretv android.permission.DUMP";
        }
        Set<Integer> active = new HashSet<>(scan.sessions);
        active.addAll(announcedSessions);
        String lastError = null;
        synchronized (effects) {
            if (globalEffect != null) {
                globalEffect.release();
                globalEffect = null;
            }
            for (Integer session : new HashSet<>(effects.keySet())) {
                if (!active.contains(session)) {
                    effects.remove(session).release();
                }
            }
            for (Integer session : active) {
                try {
                    Equalizer effect = effects.get(session);
                    if (effect == null) {
                        effect = new Equalizer(1000, session);
                        effects.put(session, effect);
                    }
                    applyGains(effect, gains);
                    effect.setEnabled(true);
                } catch (RuntimeException e) {
                    Equalizer failed = effects.remove(session);
                    if (failed != null) failed.release();
                    lastError = "Session " + session + ": " + e.getClass().getSimpleName();
                }
            }
            String status = "Detected media sessions: " + active.size()
                    + "; EQ engines: " + effects.size()
                    + "; HDMI Dolby encoding: not controlled";
            if (scan.error != null) status += "\n" + scan.error;
            if (lastError != null) status += "\n" + lastError;
            EqSettings.preferences(this).edit().putString(EqSettings.STATUS, status).apply();
        }
    }

    private static void applyGains(Equalizer effect, int[] gains) {
        short[] limits = effect.getBandLevelRange();
        for (short band = 0; band < effect.getNumberOfBands(); band++) {
            float center = effect.getCenterFreq(band) / 1000.0f;
            int millibels = Math.round(EqSettings.gainAt(center, gains) * 100.0f);
            short clamped = (short) Math.max(limits[0], Math.min(limits[1], millibels));
            effect.setBandLevel(band, clamped);
        }
    }

    @Override public void onDestroy() {
        running = false;
        EqSettings.preferences(this).edit().putBoolean(EqSettings.ENABLED, false).apply();
        unregisterReceiver(sessions);
        executor.shutdownNow();
        synchronized (effects) {
            for (Equalizer effect : effects.values()) effect.release();
            effects.clear();
            if (globalEffect != null) {
                globalEffect.release();
                globalEffect = null;
            }
        }
        super.onDestroy();
    }

    @Override public IBinder onBind(Intent intent) { return null; }
}

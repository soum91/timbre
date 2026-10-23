package com.soum91.timbretv;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.SeekBar;
import android.widget.TextView;
import android.widget.Toast;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.security.cert.X509Certificate;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;

/**
 * Ten-foot Timbre UI. Its EQ and preset controls are connected to the session
 * equalizer; unsupported DSP sections intentionally do not expose fake toggles.
 */
public final class MainActivity extends Activity {
    private static final int BG = Color.rgb(12, 13, 16);
    private static final int PANEL = Color.rgb(26, 27, 32);
    private static final int BORDER = Color.rgb(56, 51, 45);
    private static final int TEXT = Color.rgb(247, 245, 241);
    private static final int MUTED = Color.rgb(179, 176, 171);
    private static final int GOLD = Color.rgb(255, 181, 65);
    private static final int DARK_GOLD = Color.rgb(75, 56, 30);
    private static final String[] TABS = {"EQ", "Spatial", "Reverb", "Dynamics", "Presets", "Soundbar"};
    private static final String BAR_HOST_KEY = "soundbar_host";
    private static final String BAR_ROOT = "/menu_native/dynamic/audio_settings";

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final ExecutorService barWorker = Executors.newSingleThreadExecutor();
    private final Button[] tabButtons = new Button[TABS.length];
    private LinearLayout page;
    private TextView status;
    private Button power;
    private Button bypassButton;
    private int selectedTab = 0;
    private CurveView curve;
    private String barHost = "";
    private int barPort = 0;
    private String barPath;
    private String barTitle = "Audio settings";
    private String barMessage = "Enter your Vizio soundbar's LAN IP, then connect.";
    private List<BarItem> barItems = Collections.emptyList();
    private boolean barBusy = false;

    private final Runnable refresh = new Runnable() {
        @Override public void run() {
            boolean enabled = EqSettings.preferences(MainActivity.this)
                    .getBoolean(EqSettings.ENABLED, false);
            if (power != null) {
                power.setText(enabled ? "●  EQ ACTIVE  ·  STOP" : "▶  START EQ");
            }
            if (status != null) {
                status.setText(EqSettings.preferences(MainActivity.this)
                        .getString(EqSettings.STATUS,
                                "Not running. Start the EQ and play audio to check sessions."));
            }
            if (bypassButton != null) {
                boolean bypass = EqSettings.preferences(MainActivity.this)
                        .getBoolean(EqSettings.BYPASS, false);
                bypassButton.setText(bypass ? "A/B TEST: BYPASSED" : "A/B TEST: EQ ON");
            }
            handler.postDelayed(this, 2000);
        }
    };

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        barHost = EqSettings.preferences(this).getString(BAR_HOST_KEY, "");
        getWindow().setStatusBarColor(BG);
        getWindow().setNavigationBarColor(BG);
        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.setBackgroundColor(BG);

        LinearLayout root = column();
        root.setPadding(dp(30), dp(18), dp(30), dp(24));
        scroll.addView(root);

        LinearLayout header = row();
        header.setGravity(Gravity.CENTER_VERTICAL);
        root.addView(header);

        LinearLayout brand = column();
        header.addView(brand, new LinearLayout.LayoutParams(0, -2, 1f));
        brand.addView(text("Timbre", 34, TEXT, true));
        brand.addView(text("TV AUDIO LAB    /    SONY A80L", 12, GOLD, true));

        power = button("▶  START EQ");
        power.setOnClickListener(view -> {
            boolean enabled = EqSettings.preferences(this).getBoolean(EqSettings.ENABLED, false);
            Intent intent = new Intent(this, TimbreService.class);
            intent.setAction(enabled ? TimbreService.STOP : TimbreService.START);
            if (enabled) startService(intent);
            else startForegroundService(intent);
            power.setText(enabled ? "▶  START EQ" : "●  EQ ACTIVE  ·  STOP");
        });
        header.addView(power, new LinearLayout.LayoutParams(dp(196), dp(55)));

        TextView intro = text(
                "A proper remote-first interface for Timbre's accessible Android audio EQ.",
                15, MUTED, false);
        LinearLayout.LayoutParams introParams = new LinearLayout.LayoutParams(-1, -2);
        introParams.topMargin = dp(13);
        root.addView(intro, introParams);

        LinearLayout navigation = row();
        LinearLayout.LayoutParams navParams = new LinearLayout.LayoutParams(-1, dp(53));
        navParams.topMargin = dp(22);
        root.addView(navigation, navParams);
        for (int i = 0; i < TABS.length; i++) {
            final int tab = i;
            Button b = button(TABS[i]);
            b.setOnFocusChangeListener((view, hasFocus) ->
                    paintButton(b, tab == selectedTab, hasFocus));
            b.setOnClickListener(view -> selectTab(tab));
            tabButtons[i] = b;
            LinearLayout.LayoutParams bParams =
                    new LinearLayout.LayoutParams(0, -1, 1f);
            bParams.rightMargin = dp(9);
            navigation.addView(b, bParams);
        }

        page = column();
        LinearLayout.LayoutParams pageParams = new LinearLayout.LayoutParams(-1, -2);
        pageParams.topMargin = dp(20);
        root.addView(page, pageParams);

        LinearLayout diagnostics = card();
        LinearLayout.LayoutParams diagParams = new LinearLayout.LayoutParams(-1, -2);
        diagParams.topMargin = dp(15);
        root.addView(diagnostics, diagParams);
        diagnostics.addView(text("PLAYBACK STATUS", 13, GOLD, true));
        status = text("Checking audio sessions...", 15, MUTED, false);
        LinearLayout.LayoutParams statusParams = new LinearLayout.LayoutParams(-1, -2);
        statusParams.topMargin = dp(7);
        diagnostics.addView(status, statusParams);
        bypassButton = button("A/B TEST: EQ ON");
        LinearLayout.LayoutParams bypassParams = new LinearLayout.LayoutParams(dp(260), dp(50));
        bypassParams.topMargin = dp(12);
        diagnostics.addView(bypassButton, bypassParams);
        bypassButton.setOnClickListener(v -> {
            boolean previous = EqSettings.preferences(this).getBoolean(EqSettings.BYPASS, false);
            EqSettings.preferences(this).edit().putBoolean(EqSettings.BYPASS, !previous).apply();
            bypassButton.setText(previous ? "A/B TEST: EQ ON" : "A/B TEST: BYPASSED");
            applyToService();
        });
        diagnostics.addView(text("Listen for a difference when switching EQ on/off. "
                + "A successful engine readback is not proof that Dolby or other protected "
                + "audio passes through it.", 13, MUTED, false));
        TextView nativeStatus = text(NativeDsp.isReady()
                ? "NATIVE DSP  ·  Original 16-band C++ engine linked and self-tested (offline PCM only)"
                : "NATIVE DSP  ·  Not available on this Android build",
                12, GOLD, true);
        LinearLayout.LayoutParams nativeParams = new LinearLayout.LayoutParams(-1, -2);
        nativeParams.topMargin = dp(9);
        diagnostics.addView(nativeStatus, nativeParams);

        setContentView(scroll);
        selectTab(0);
        power.requestFocus();
    }

    @Override public void onStart() {
        super.onStart();
        handler.removeCallbacks(refresh);
        handler.post(refresh);
    }

    @Override public void onStop() {
        handler.removeCallbacks(refresh);
        super.onStop();
    }

    @Override public void onDestroy() {
        barWorker.shutdownNow();
        super.onDestroy();
    }

    private void selectTab(int tab) {
        selectedTab = tab;
        for (int i = 0; i < tabButtons.length; i++) {
            paintButton(tabButtons[i], selectedTab == i, tabButtons[i].hasFocus());
        }
        page.removeAllViews();
        curve = null;
        switch (tab) {
            case 0: showEq(); break;
            case 1: showUnavailable("Spatial", "HEADPHONE PROCESSING",
                    "The iPhone tweak's immersive HRTF and head tracking are designed "
                            + "for headphone rendering. Sony's Android audio session API "
                            + "does not expose Timbre's original binaural DSP chain. "
                            + "The Vizio Elevate's native Dolby Atmos decoding should "
                            + "stay intact rather than feeding it virtual headphone surround."); break;
            case 2: showUnavailable("Reverb", "ROOM / STUDIO / PLATE / HALL",
                    "The tweak's mix, decay, pre-delay, damping and stereo width "
                            + "require control over PCM samples or a compatible auxiliary "
                            + "audio effect. This rootless TV build has neither a verified "
                            + "reverb effect path nor the ability to re-encode Dolby."); break;
            case 3: showUnavailable("Dynamics", "COMPRESSOR / LIMITER",
                    "The Sony audio stack advertises Android DynamicsProcessing, "
                            + "but a working per-app session connection and usable "
                            + "compression parameters have not been validated. "
                            + "Threshold, ratio, knee, attack, release and makeup "
                            + "will only become adjustable after that integration works."); break;
            case 4: showPresets(); break;
            case 5: showSoundbar(); break;
            default: break;
        }
    }

    private void showEq() {
        LinearLayout top = row();
        top.setGravity(Gravity.CENTER_VERTICAL);
        page.addView(top);
        top.addView(text("Equalizer", 26, TEXT, true),
                new LinearLayout.LayoutParams(0, -2, 1f));
        top.addView(text("ANDROID PLATFORM EQ", 12, GOLD, true));

        LinearLayout routing = card();
        LinearLayout.LayoutParams routingParams = new LinearLayout.LayoutParams(-1, -2);
        routingParams.topMargin = dp(12);
        page.addView(routing, routingParams);
        LinearLayout routingRow = row();
        routingRow.setGravity(Gravity.CENTER_VERTICAL);
        routing.addView(routingRow);
        LinearLayout routingText = column();
        routingRow.addView(routingText, new LinearLayout.LayoutParams(0, -2, 1f));
        routingText.addView(text("AUDIO ROUTING", 13, GOLD, true));
        routingText.addView(text("Experimental global output mix (session 0)", 17, TEXT, true));
        boolean global = EqSettings.preferences(this).getBoolean(EqSettings.GLOBAL_MIX, false);
        Button routeMode = button(global ? "GLOBAL MIX: ON" : "GLOBAL MIX: OFF");
        routingRow.addView(routeMode, new LinearLayout.LayoutParams(dp(240), dp(49)));
        routeMode.setOnClickListener(v -> {
            boolean next = !EqSettings.preferences(this)
                    .getBoolean(EqSettings.GLOBAL_MIX, false);
            EqSettings.preferences(this).edit().putBoolean(EqSettings.GLOBAL_MIX, next).apply();
            routeMode.setText(next ? "GLOBAL MIX: ON" : "GLOBAL MIX: OFF");
            applyToService();
        });
        TextView routingNote = text("OFF: track individual app sessions (requires ADB DUMP grant).  "
                + "ON: use Android's deprecated global output EQ without session tracking. "
                + "Turn off Poweramp EQ during testing. Dolby passthrough can bypass this effect; "
                + "an attached engine does not prove audible processing.", 13, MUTED, false);
        LinearLayout.LayoutParams noteParams = new LinearLayout.LayoutParams(-1, -2);
        noteParams.topMargin = dp(8);
        routing.addView(routingNote, noteParams);

        LinearLayout body = row();
        LinearLayout.LayoutParams bodyParams = new LinearLayout.LayoutParams(-1, -2);
        bodyParams.topMargin = dp(12);
        page.addView(body, bodyParams);

        LinearLayout graphCard = card();
        LinearLayout.LayoutParams graphParams =
                new LinearLayout.LayoutParams(0, dp(435), 1.35f);
        graphParams.rightMargin = dp(14);
        body.addView(graphCard, graphParams);
        graphCard.addView(text("RESPONSE CURVE", 13, GOLD, true));
        graphCard.addView(text("Gain + Q-shaped points sampled onto Android's fixed EQ bands",
                13, MUTED, false));
        curve = new CurveView();
        curve.setCurve(EqSettings.readCurve(this));
        LinearLayout.LayoutParams curveParams =
                new LinearLayout.LayoutParams(-1, 0, 1f);
        curveParams.topMargin = dp(14);
        graphCard.addView(curve, curveParams);

        LinearLayout controls = card();
        body.addView(controls, new LinearLayout.LayoutParams(0, dp(435), 1f));
        LinearLayout bandHeader = row();
        bandHeader.setGravity(Gravity.CENTER_VERTICAL);
        controls.addView(bandHeader);
        bandHeader.addView(text("CONTROL POINTS", 13, GOLD, true),
                new LinearLayout.LayoutParams(0, -2, 1f));
        Button add = button("+ ADD BAND");
        bandHeader.addView(add, new LinearLayout.LayoutParams(dp(150), dp(46)));
        add.setOnClickListener(v -> promptAddBand());
        ScrollView bandsScroll = new ScrollView(this);
        bandsScroll.setFillViewport(false);
        controls.addView(bandsScroll, new LinearLayout.LayoutParams(-1, 0, 1f));
        LinearLayout bands = column();
        bandsScroll.addView(bands);
        EqSettings.Curve selectedCurve = EqSettings.readCurve(this);
        for (int i = 0; i < selectedCurve.frequencies.length; i++) {
            final int index = i;
            LinearLayout line = row();
            line.setGravity(Gravity.CENTER_VERTICAL);
            LinearLayout.LayoutParams lineParams = new LinearLayout.LayoutParams(-1, -2);
            lineParams.topMargin = dp(13);
            bands.addView(line, lineParams);

            TextView label = text(frequencyLabel(selectedCurve.frequencies[i]),
                    16, TEXT, true);
            line.addView(label, new LinearLayout.LayoutParams(0, -2, 1f));
            TextView amount = text(gainLabel(selectedCurve.gains[i]), 16, GOLD, true);
            line.addView(amount);
            Button remove = button("×");
            LinearLayout.LayoutParams removeParams = new LinearLayout.LayoutParams(dp(48), dp(42));
            removeParams.leftMargin = dp(7);
            line.addView(remove, removeParams);
            remove.setContentDescription("Remove " + frequencyLabel(selectedCurve.frequencies[i]));
            remove.setOnClickListener(v -> {
                if (EqSettings.removeBand(this, index)) {
                    applyToService();
                    selectTab(0);
                } else {
                    Toast.makeText(this, "Keep at least two EQ points", Toast.LENGTH_SHORT).show();
                }
            });

            SeekBar seekBar = new SeekBar(this);
            seekBar.setMax(24);
            seekBar.setProgress(selectedCurve.gains[i] + 12);
            seekBar.setProgressTintList(android.content.res.ColorStateList.valueOf(GOLD));
            seekBar.setThumbTintList(android.content.res.ColorStateList.valueOf(TEXT));
            seekBar.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
                @Override public void onProgressChanged(SeekBar bar, int value, boolean user) {
                    int gain = value - 12;
                    amount.setText(gainLabel(gain));
                    if (user) {
                        EqSettings.saveGain(MainActivity.this, index, gain);
                        if (curve != null) curve.setCurve(EqSettings.readCurve(MainActivity.this));
                        applyToService();
                    }
                }
                @Override public void onStartTrackingTouch(SeekBar bar) {}
                @Override public void onStopTrackingTouch(SeekBar bar) {}
            });
            LinearLayout.LayoutParams sliderParams = new LinearLayout.LayoutParams(-1, dp(28));
            bands.addView(seekBar, sliderParams);

            TextView qLabel = text(String.format(Locale.US, "BAND WIDTH  ·  Q %.1f",
                    selectedCurve.qValues[i]), 13, MUTED, true);
            LinearLayout.LayoutParams qLabelParams = new LinearLayout.LayoutParams(-1, -2);
            qLabelParams.topMargin = dp(2);
            bands.addView(qLabel, qLabelParams);
            SeekBar qSlider = new SeekBar(this);
            qSlider.setMax(Math.round((EqSettings.MAX_Q - EqSettings.MIN_Q) * 10));
            qSlider.setProgress(Math.round((selectedCurve.qValues[i] - EqSettings.MIN_Q) * 10));
            qSlider.setProgressTintList(android.content.res.ColorStateList.valueOf(GOLD));
            qSlider.setThumbTintList(android.content.res.ColorStateList.valueOf(TEXT));
            qSlider.setContentDescription("Q width for "
                    + frequencyLabel(selectedCurve.frequencies[i]));
            qSlider.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
                @Override public void onProgressChanged(SeekBar bar, int progress, boolean user) {
                    float q = EqSettings.MIN_Q + progress / 10f;
                    qLabel.setText(String.format(Locale.US, "BAND WIDTH  ·  Q %.1f", q));
                    if (user) {
                        EqSettings.saveQ(MainActivity.this, index, q);
                        if (curve != null) curve.setCurve(EqSettings.readCurve(MainActivity.this));
                        applyToService();
                    }
                }
                @Override public void onStartTrackingTouch(SeekBar bar) {}
                @Override public void onStopTrackingTouch(SeekBar bar) {}
            });
            bands.addView(qSlider, new LinearLayout.LayoutParams(-1, dp(28)));
        }

        bands.addView(text("Q 1.0 preserves the previous curve. Higher Q narrows a point's "
                + "influence between adjacent points; lower Q broadens it. The TV EQ "
                + "samples that shape onto fixed hardware bands, so this is NOT a true "
                + "parametric Q filter.", 12, MUTED, false));

        LinearLayout gainCard = card();
        LinearLayout.LayoutParams gainParams = new LinearLayout.LayoutParams(-1, -2);
        gainParams.topMargin = dp(13);
        page.addView(gainCard, gainParams);
        int globalGain = EqSettings.preferences(this).getInt(EqSettings.GLOBAL_GAIN, 0);
        TextView gainTitle = text("MASTER GAIN  " + gainLabel(globalGain), 16, GOLD, true);
        gainCard.addView(gainTitle);
        SeekBar gainSlider = new SeekBar(this);
        gainSlider.setMax(24);
        gainSlider.setProgress(globalGain + 12);
        gainSlider.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override public void onProgressChanged(SeekBar bar, int progress, boolean user) {
                int db = progress - 12;
                gainTitle.setText("MASTER GAIN  " + gainLabel(db));
                if (user) {
                    EqSettings.preferences(MainActivity.this).edit()
                            .putInt(EqSettings.GLOBAL_GAIN, db).apply();
                    applyToService();
                }
            }
            @Override public void onStartTrackingTouch(SeekBar bar) {}
            @Override public void onStopTrackingTouch(SeekBar bar) {}
        });
        gainCard.addView(gainSlider);
        gainCard.addView(text("Android DynamicsProcessing input gain where supported. "
                + "If unavailable, Timbre reports an EQ-band offset fallback. "
                + "Positive gain may clip.", 13, MUTED, false));

        LinearLayout footer = row();
        LinearLayout.LayoutParams footerParams = new LinearLayout.LayoutParams(-1, dp(54));
        footerParams.topMargin = dp(15);
        page.addView(footer, footerParams);
        Button flat = button("Reset curve");
        flat.setOnClickListener(v -> {
            EqSettings.applyPreset(this, new int[]{0, 0, 0, 0, 0});
            applyToService();
            selectTab(0);
        });
        footer.addView(flat, new LinearLayout.LayoutParams(dp(190), -1));
        Button save = button("Save as My curve");
        LinearLayout.LayoutParams saveParams = new LinearLayout.LayoutParams(dp(225), -1);
        saveParams.leftMargin = dp(12);
        footer.addView(save, saveParams);
        save.setOnClickListener(v -> {
            EqSettings.saveCustomPreset(this);
            Toast.makeText(this, "Saved to Presets → My curve", Toast.LENGTH_SHORT).show();
        });
        TextView info = text("D-pad: focus a slider, then use ◀  ▶ to change gain.",
                13, MUTED, false);
        info.setGravity(Gravity.CENTER_VERTICAL | Gravity.RIGHT);
        footer.addView(info, new LinearLayout.LayoutParams(0, -1, 1f));
    }

    private void showPresets() {
        page.addView(text("Presets", 26, TEXT, true));
        page.addView(text("Profiles apply real band gains to the Android session EQ. "
                + "They do not switch Dolby codecs or output devices.", 15, MUTED, false));

        presetRow("Flat", new int[]{0, 0, 0, 0, 0},
                "Neutral response with no added gain.");
        presetRow("Bass Boost", new int[]{6, 4, 1, 0, 0},
                "Extra low-end weight.");
        presetRow("V-Shape", new int[]{5, 2, -3, 2, 5},
                "Stronger lows and highs.");
        presetRow("Vocal Presence", new int[]{-2, 0, 3, 4, 1},
                "Bring dialogue frequencies forward.");
        presetRow("Treble Boost", new int[]{0, 0, 1, 4, 6},
                "Add definition in the upper bands.");
        presetRow("Late Night Loudness", new int[]{2, 1, 3, 1, -2},
                "A fixed tonal profile, not a dynamics compressor.");
        EqSettings.Curve custom = EqSettings.readCustomPreset(this);
        if (custom != null) {
            LinearLayout customCard = row();
            customCard.setGravity(Gravity.CENTER_VERTICAL);
            customCard.setBackground(panelBackground(PANEL, BORDER));
            customCard.setPadding(dp(18), dp(8), dp(14), dp(8));
            LinearLayout.LayoutParams customParams = new LinearLayout.LayoutParams(-1, dp(75));
            customParams.topMargin = dp(11);
            page.addView(customCard, customParams);
            customCard.addView(text("My curve (" + custom.frequencies.length + " points)",
                    20, TEXT, true), new LinearLayout.LayoutParams(0, -2, 1f));
            Button restore = button("RESTORE");
            customCard.addView(restore, new LinearLayout.LayoutParams(dp(140), dp(46)));
            restore.setOnClickListener(v -> {
                EqSettings.saveCurve(this, custom);
                applyToService();
                selectTab(0);
            });
        }
        else {
            LinearLayout c = card();
            LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(-1, -2);
            params.topMargin = dp(12);
            page.addView(c, params);
            c.addView(text("MY CURVE", 13, GOLD, true));
            c.addView(text("Save your adjusted EQ from the EQ tab to add a personal preset.",
                    15, MUTED, false));
        }
    }

    /**
     * Soundbar EQ works after the bar decodes its incoming HDMI signal. This
     * deliberately does not alter the TV's Atmos/E-AC3 output or claim to do so.
     * The settings browser follows the soundbar's own SmartCast audio menu,
     * following the approach in soum91/subwave rather than guessing EQ paths.
     */
    private void showSoundbar() {
        page.addView(text("Vizio Elevate", 26, TEXT, true));
        page.addView(text("Native soundbar processing  ·  Dolby Atmos passthrough stays untouched",
                14, GOLD, true));

        LinearLayout connect = card();
        LinearLayout.LayoutParams connectParams = new LinearLayout.LayoutParams(-1, -2);
        connectParams.topMargin = dp(13);
        page.addView(connect, connectParams);
        connect.addView(text("SMARTCAST LAN CONNECTION", 13, GOLD, true));
        connect.addView(text("Use the same Wi-Fi/LAN as your soundbar. Enter the bar's private IPv4 "
                + "address, not the Sony TV's address.", 14, MUTED, false));

        LinearLayout entry = row();
        entry.setGravity(Gravity.CENTER_VERTICAL);
        LinearLayout.LayoutParams entryParams = new LinearLayout.LayoutParams(-1, -2);
        entryParams.topMargin = dp(12);
        connect.addView(entry, entryParams);
        EditText address = new EditText(this);
        address.setSingleLine(true);
        address.setTextColor(TEXT);
        address.setHintTextColor(MUTED);
        address.setHint("192.168.1.100");
        address.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        address.setText(barHost);
        address.setContentDescription("Soundbar LAN IPv4 address");
        entry.addView(address, new LinearLayout.LayoutParams(0, dp(55), 1f));

        Button discover = button(barBusy ? "CONNECTING..." : "CONNECT / REFRESH");
        discover.setEnabled(!barBusy);
        LinearLayout.LayoutParams buttonParams = new LinearLayout.LayoutParams(dp(245), dp(52));
        buttonParams.leftMargin = dp(12);
        entry.addView(discover, buttonParams);
        discover.setOnClickListener(v -> {
            String host = address.getText().toString().trim();
            if (!isPrivateIPv4(host)) {
                Toast.makeText(this, "Enter a private LAN IPv4 (10.x, 172.16-31.x, "
                        + "or 192.168.x)", Toast.LENGTH_LONG).show();
                return;
            }
            boolean newHost = !host.equals(barHost);
            barHost = host;
            EqSettings.preferences(this).edit().putString(BAR_HOST_KEY, host).apply();
            if (newHost) {
                barPort = 0;
                barPath = null;
                barItems = Collections.emptyList();
            }
            connectToBar();
        });
        connect.addView(text("Uses the bar's HTTPS SmartCast API (ports 7345/9000). "
                + "No cloud account or HDMI audio interception is required.",
                12, MUTED, false));

        LinearLayout settings = card();
        LinearLayout.LayoutParams settingsParams = new LinearLayout.LayoutParams(-1, -2);
        settingsParams.topMargin = dp(13);
        page.addView(settings, settingsParams);
        settings.addView(text("SOUNDBAR RESPONSE", 13, GOLD, true));
        settings.addView(text(barMessage, 15, barMessage.startsWith("Error") ? GOLD : TEXT, false));
        if (barPort > 0) {
            settings.addView(text("Connected over HTTPS port " + barPort
                    + "  ·  Controls verified only by device readback", 12, MUTED, false));
        }
        if (barPath == null) {
            settings.addView(text("Once connected, Timbre will show the controls the "
                    + "soundbar actually exposes: EQ mode, bass, treble, surrounds, "
                    + "height and other audio settings where available.",
                    14, MUTED, false));
            return;
        }

        LinearLayout menuHeader = row();
        menuHeader.setGravity(Gravity.CENTER_VERTICAL);
        LinearLayout.LayoutParams headerParams = new LinearLayout.LayoutParams(-1, -2);
        headerParams.topMargin = dp(13);
        page.addView(menuHeader, headerParams);
        Button back = button("◀  UP");
        back.setEnabled(!barBusy && !BAR_ROOT.equals(barPath));
        menuHeader.addView(back, new LinearLayout.LayoutParams(dp(125), dp(49)));
        back.setOnClickListener(v -> {
            int slash = barPath.lastIndexOf('/');
            if (slash < BAR_ROOT.length()) return;
            String parent = barPath.substring(0, slash);
            loadBarMenu(parent, "Audio settings");
        });
        TextView title = text(barTitle, 21, TEXT, true);
        title.setPadding(dp(16), 0, 0, 0);
        menuHeader.addView(title, new LinearLayout.LayoutParams(0, -2, 1f));
        Button reload = button("RELOAD MENU");
        reload.setEnabled(!barBusy);
        menuHeader.addView(reload, new LinearLayout.LayoutParams(dp(195), dp(49)));
        reload.setOnClickListener(v -> loadBarMenu(barPath, barTitle));

        if (barItems.isEmpty()) {
            page.addView(text("No settings returned in this menu.", 15, MUTED, false));
        }
        for (BarItem item : barItems) {
            if (!item.hidden) addBarSetting(item);
        }
        page.addView(text("Changing these controls adjusts the soundbar's own decoder/output "
                + "processing. It cannot force the TV or a streaming app to transmit Atmos. "
                + "Check the soundbar's input-format indicator separately.",
                13, MUTED, false));
    }

    private void addBarSetting(BarItem item) {
        LinearLayout card = card();
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(-1, -2);
        params.topMargin = dp(9);
        page.addView(card, params);
        LinearLayout line = row();
        line.setGravity(Gravity.CENTER_VERTICAL);
        card.addView(line);
        LinearLayout description = column();
        line.addView(description, new LinearLayout.LayoutParams(0, -2, 1f));
        description.addView(text(item.name, 18, TEXT, true));
        if (!item.isMenu()) {
            description.addView(text(item.displayValue() + (item.readOnly ? "  ·  READ ONLY" : ""),
                    14, MUTED, false));
        }
        if (item.isMenu()) {
            Button open = button("OPEN  ▶");
            open.setEnabled(!barBusy);
            line.addView(open, new LinearLayout.LayoutParams(dp(170), dp(48)));
            open.setOnClickListener(v -> loadBarMenu(item.path, item.name));
        } else if (!item.readOnly && item.choices.size() > 0) {
            Button choose = button("CHANGE  ▾");
            choose.setEnabled(!barBusy);
            line.addView(choose, new LinearLayout.LayoutParams(dp(170), dp(48)));
            choose.setOnClickListener(v -> new AlertDialog.Builder(this)
                    .setTitle(item.name)
                    .setItems(item.choices.toArray(new String[0]), (dialog, selected) ->
                            setBarValue(item, item.choices.get(selected)))
                    .setNegativeButton("Cancel", null).show());
        } else if (item.isSlider() && !item.readOnly) {
            int min = item.min;
            int max = item.max;
            SeekBar slider = new SeekBar(this);
            slider.setMax(max - min);
            slider.setProgress(Math.min(max, Math.max(min, item.intValue())) - min);
            slider.setProgressTintList(android.content.res.ColorStateList.valueOf(GOLD));
            slider.setThumbTintList(android.content.res.ColorStateList.valueOf(TEXT));
            slider.setEnabled(!barBusy);
            slider.setContentDescription(item.name + " soundbar adjustment");
            TextView value = text(item.displayValue(), 16, GOLD, true);
            line.addView(value, new LinearLayout.LayoutParams(dp(100), -2));
            slider.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
                @Override public void onProgressChanged(SeekBar seek, int progress, boolean user) {
                    if (user) value.setText(String.valueOf(min + progress));
                }
                @Override public void onStartTrackingTouch(SeekBar seek) {}
                @Override public void onStopTrackingTouch(SeekBar seek) {
                    int newValue = min + seek.getProgress();
                    if (newValue != item.intValue()) setBarValue(item, newValue);
                }
            });
            card.addView(slider, new LinearLayout.LayoutParams(-1, dp(42)));
        }
    }

    private interface BarJob { void run() throws Exception; }

    private void runBarJob(BarJob job) {
        if (barBusy) return;
        barBusy = true;
        if (selectedTab == 5) selectTab(5);
        barWorker.execute(() -> {
            try {
                job.run();
            } catch (Exception e) {
                String detail = e.getMessage() == null ? e.getClass().getSimpleName() : e.getMessage();
                barMessage = "Error: " + detail;
            }
            handler.post(() -> {
                barBusy = false;
                if (!isFinishing() && !isDestroyed() && selectedTab == 5) selectTab(5);
            });
        });
    }

    private void connectToBar() {
        runBarJob(() -> {
            BarClient client = null;
            Exception last = null;
            int[] ports = barPort > 0 ? new int[]{barPort, barPort == 7345 ? 9000 : 7345}
                    : new int[]{7345, 9000};
            for (int port : ports) {
                try {
                    BarClient candidate = new BarClient(barHost, port);
                    candidate.request("GET", BAR_ROOT, null);
                    client = candidate;
                    barPort = port;
                    break;
                } catch (Exception e) { last = e; }
            }
            if (client == null) {
                throw new IOException("Soundbar unavailable on HTTPS 7345/9000. "
                        + "Check its LAN IP/Wi-Fi. "
                        + (last == null ? "" : last.getMessage()));
            }
            List<BarItem> root = client.menu(BAR_ROOT);
            String audioPath = BAR_ROOT;
            for (BarItem it : root) {
                if (it.isMenu() && (it.cname.equalsIgnoreCase("audio")
                        || (it.cname + it.name).toLowerCase(Locale.US).contains("audio"))) {
                    audioPath = it.path;
                    break;
                }
            }
            barItems = client.menu(audioPath);
            barPath = audioPath;
            barTitle = "Audio settings";
            barMessage = "Connected. " + barItems.size()
                    + " settings received from the soundbar.";
        });
    }

    private void loadBarMenu(String path, String title) {
        runBarJob(() -> {
            List<BarItem> found = new BarClient(barHost, barPort).menu(path);
            barItems = found;
            barPath = path;
            barTitle = title;
            barMessage = "Read " + found.size() + " settings from the soundbar.";
        });
    }

    private void setBarValue(BarItem item, Object value) {
        if (item.readOnly || item.isMenu()) return;
        runBarJob(() -> {
            BarClient client = new BarClient(barHost, barPort);
            BarItem current = client.item(item);
            if (current.hash == null) throw new IOException("No HASHVAL for " + item.name);
            JSONObject body = new JSONObject();
            body.put("REQUEST", "MODIFY");
            body.put("HASHVAL", current.hash);
            body.put("VALUE", value);
            client.request("PUT", item.path, body);
            BarItem confirmed = client.item(item);
            List<BarItem> updated = client.menu(barPath);
            barItems = updated;
            barMessage = item.name + ": device readback " + confirmed.displayValue()
                    + ". This verifies the bar's setting, not the HDMI codec.";
        });
    }

    private static boolean isPrivateIPv4(String host) {
        String[] parts = host.split("\\.", -1);
        if (parts.length != 4) return false;
        int[] nums = new int[4];
        try {
            for (int i = 0; i < 4; i++) {
                if (parts[i].isEmpty() || parts[i].length() > 3) return false;
                for (int j = 0; j < parts[i].length(); j++) {
                    char digit = parts[i].charAt(j);
                    if (digit < '0' || digit > '9') return false;
                }
                nums[i] = Integer.parseInt(parts[i]);
                if (nums[i] < 0 || nums[i] > 255) return false;
            }
        } catch (NumberFormatException e) { return false; }
        return nums[0] == 10 || nums[0] == 192 && nums[1] == 168
                || nums[0] == 172 && nums[1] >= 16 && nums[1] <= 31;
    }

    private static Object ci(JSONObject object, String key) {
        if (object == null) return null;
        Object value = object.opt(key);
        if (value == null) value = object.opt(key.toUpperCase(Locale.US));
        if (value == null) {
            java.util.Iterator<String> keys = object.keys();
            while (keys.hasNext()) {
                String candidate = keys.next();
                if (candidate.equalsIgnoreCase(key)) return object.opt(candidate);
            }
        }
        return value == JSONObject.NULL ? null : value;
    }

    private static String string(Object value) {
        return value == null || value == JSONObject.NULL ? "" : String.valueOf(value);
    }

    private static Integer integer(Object value) {
        if (value instanceof Number) return ((Number) value).intValue();
        try { return value == null ? null : Integer.parseInt(string(value)); }
        catch (NumberFormatException e) { return null; }
    }

    private static final class BarItem {
        final String cname;
        final String name;
        final String type;
        final String path;
        final Object value;
        Integer hash;
        Integer min;
        Integer max;
        boolean readOnly;
        boolean hidden;
        final List<String> choices = new ArrayList<>();

        BarItem(JSONObject source, String parent) {
            cname = string(ci(source, "cname"));
            name = string(ci(source, "name")).isEmpty() ? cname : string(ci(source, "name"));
            type = string(ci(source, "type")).toLowerCase(Locale.US);
            path = parent + "/" + cname;
            Object raw = ci(source, "value");
            value = raw instanceof JSONObject ? ci((JSONObject) raw, "name") : raw;
            hash = integer(ci(source, "hashval"));
            min = integer(ci(source, "minimum"));
            max = integer(ci(source, "maximum"));
            readOnly = Boolean.parseBoolean(string(ci(source, "readonly")));
            hidden = Boolean.parseBoolean(string(ci(source, "hidden")));
            JSONArray elements = ci(source, "elements") instanceof JSONArray
                    ? (JSONArray) ci(source, "elements") : null;
            if (elements != null) {
                for (int i = 0; i < elements.length(); i++) {
                    String choice = string(elements.opt(i));
                    if (!choice.isEmpty()) choices.add(choice);
                }
            }
        }

        boolean isMenu() { return type.equals("t_menu_v1") || type.equals("t_audio_menu_v1"); }
        boolean isSlider() {
            return min != null && max != null && max > min && max - min <= 1000
                    && integer(value) != null;
        }
        int intValue() { Integer v = integer(value); return v == null ? (min == null ? 0 : min) : v; }
        String displayValue() { return string(value).isEmpty() ? "Unavailable" : string(value); }
    }

    /**
     * SmartCast exposes a self-signed HTTPS endpoint on the user's local bar.
     * Certificate relaxation is applied only to a connection to an explicitly
     * entered RFC1918 IPv4 host, never to the app or system TLS defaults.
     */
    private static final class BarClient {
        private final String host;
        private final int port;
        private final javax.net.ssl.SSLSocketFactory localTls;

        BarClient(String address, int soundbarPort) throws Exception {
            if (!isPrivateIPv4(address)) throw new IOException("Only private LAN IPv4 allowed");
            if (soundbarPort != 7345 && soundbarPort != 9000) {
                throw new IOException("Unsupported SmartCast port");
            }
            host = address;
            port = soundbarPort;
            X509TrustManager trust = new X509TrustManager() {
                @Override public void checkClientTrusted(X509Certificate[] chain, String authType) {}
                @Override public void checkServerTrusted(X509Certificate[] chain, String authType) {}
                @Override public X509Certificate[] getAcceptedIssuers() {
                    return new X509Certificate[0];
                }
            };
            SSLContext ssl = SSLContext.getInstance("TLS");
            ssl.init(null, new TrustManager[]{trust}, new SecureRandom());
            localTls = ssl.getSocketFactory();
        }

        JSONObject request(String method, String path, JSONObject body) throws Exception {
            if (!path.startsWith(BAR_ROOT) && !path.startsWith(
                    BAR_ROOT.replace("/dynamic/", "/static/"))) {
                throw new IOException("SmartCast request outside audio settings");
            }
            HttpsURLConnection connection = (HttpsURLConnection) new URL(
                    "https://" + host + ":" + port + path).openConnection();
            connection.setSSLSocketFactory(localTls);
            connection.setHostnameVerifier((serverName, session) -> host.equals(serverName));
            connection.setConnectTimeout(3500);
            connection.setReadTimeout(4500);
            connection.setUseCaches(false);
            connection.setRequestMethod(method);
            connection.setRequestProperty("Accept", "application/json");
            try {
                if (body != null) {
                    connection.setDoOutput(true);
                    connection.setRequestProperty("Content-Type", "application/json");
                    byte[] bytes = body.toString().getBytes(StandardCharsets.UTF_8);
                    try (OutputStream output = connection.getOutputStream()) {
                        output.write(bytes);
                    }
                }
                int code = connection.getResponseCode();
                InputStream response = code >= 400
                        ? connection.getErrorStream() : connection.getInputStream();
                if (response == null) throw new IOException("Soundbar HTTP " + code);
                ByteArrayOutputStream buffer = new ByteArrayOutputStream();
                try (InputStream input = response) {
                    byte[] chunk = new byte[4096];
                    int n;
                    while ((n = input.read(chunk)) != -1) buffer.write(chunk, 0, n);
                    if (buffer.size() > 1024 * 1024) throw new IOException("Oversized SmartCast response");
                }
                JSONObject result = new JSONObject(new String(
                        buffer.toByteArray(), StandardCharsets.UTF_8));
                JSONObject status = ci(result, "status") instanceof JSONObject
                        ? (JSONObject) ci(result, "status") : null;
                String outcome = string(ci(status, "result"));
                if (code >= 400 || !"success".equalsIgnoreCase(outcome)) {
                    String detail = string(ci(status, "detail"));
                    if (code == 403 || outcome.toLowerCase(Locale.US).contains("pair")) {
                        throw new IOException("Bar requires SmartCast pairing (HTTP " + code + ")");
                    }
                    throw new IOException("Bar rejected " + method + " (HTTP " + code
                            + "): " + (detail.isEmpty() ? outcome : detail));
                }
                return result;
            } finally {
                connection.disconnect();
            }
        }

        List<BarItem> menu(String path) throws Exception {
            List<BarItem> found = parseMenu(request("GET", path, null), path);
            String staticPath = path.replace("/dynamic/", "/static/");
            try {
                List<BarItem> options = parseMenu(request("GET", staticPath, null), staticPath);
                for (BarItem item : found) {
                    for (BarItem option : options) {
                        if (item.cname.equals(option.cname)) {
                            if (item.min == null) item.min = option.min;
                            if (item.max == null) item.max = option.max;
                            if (item.choices.isEmpty()) item.choices.addAll(option.choices);
                            break;
                        }
                    }
                }
            } catch (Exception ignored) {
                // Older firmware exposes only the dynamic menu. Readable settings
                // still appear, but missing range/choice metadata stays read-only.
            }
            return found;
        }

        BarItem item(BarItem requested) throws Exception {
            List<BarItem> values = parseMenu(request("GET", requested.path, null),
                    requested.path.substring(0, requested.path.lastIndexOf('/')));
            for (BarItem value : values) {
                if (value.cname.equals(requested.cname)) return value;
            }
            if (!values.isEmpty()) return values.get(0);
            throw new IOException("Missing soundbar setting " + requested.name);
        }

        private static List<BarItem> parseMenu(JSONObject response, String parent) {
            JSONArray array = ci(response, "items") instanceof JSONArray
                    ? (JSONArray) ci(response, "items") : null;
            List<BarItem> items = new ArrayList<>();
            if (array == null) return items;
            for (int i = 0; i < array.length(); i++) {
                JSONObject raw = array.optJSONObject(i);
                if (raw == null) continue;
                BarItem item = new BarItem(raw, parent);
                // CNAME is supplied by the bar and becomes a URL path segment.
                if (item.cname.matches("[a-zA-Z0-9_-]+")) items.add(item);
            }
            return items;
        }
    }

    private void presetRow(String name, int[] gains, String description) {
        LinearLayout c = row();
        c.setGravity(Gravity.CENTER_VERTICAL);
        c.setBackground(panelBackground(PANEL, BORDER));
        c.setPadding(dp(18), dp(8), dp(14), dp(8));
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(-1, dp(75));
        params.topMargin = dp(11);
        page.addView(c, params);
        LinearLayout labels = column();
        c.addView(labels, new LinearLayout.LayoutParams(0, -2, 1f));
        labels.addView(text(name, 20, TEXT, true));
        labels.addView(text(description, 13, MUTED, false));
        Button apply = button("APPLY");
        c.addView(apply, new LinearLayout.LayoutParams(dp(140), dp(46)));
        apply.setOnClickListener(v -> {
            EqSettings.applyPreset(this, gains);
            applyToService();
            selectTab(0);
            Toast.makeText(this, "Applied " + name, Toast.LENGTH_SHORT).show();
        });
    }

    private void promptAddBand() {
        EditText frequency = new EditText(this);
        frequency.setSingleLine(true);
        frequency.setInputType(InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_FLAG_DECIMAL);
        frequency.setHint("e.g. 125, 500, 3000");
        LinearLayout wrapper = column();
        wrapper.setPadding(dp(22), 0, dp(22), 0);
        wrapper.addView(frequency);
        new AlertDialog.Builder(this)
                .setTitle("Add frequency point (20 - 20000 Hz)")
                .setView(wrapper)
                .setNegativeButton("Cancel", null)
                .setPositiveButton("Add", (dialog, which) -> {
                    try {
                        float hz = Float.parseFloat(frequency.getText().toString().trim());
                        if (!EqSettings.addBand(this, hz)) {
                            Toast.makeText(this, "Invalid, duplicate, or 128-point limit",
                                    Toast.LENGTH_LONG).show();
                            return;
                        }
                        applyToService();
                        selectTab(0);
                    } catch (NumberFormatException e) {
                        Toast.makeText(this, "Enter a frequency in Hz", Toast.LENGTH_LONG).show();
                    }
                }).show();
    }

    private void showUnavailable(String title, String subtitle, String explanation) {
        page.addView(text(title, 26, TEXT, true));
        LinearLayout p = card();
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(-1, dp(285));
        params.topMargin = dp(13);
        page.addView(p, params);
        p.addView(text(subtitle, 13, GOLD, true));
        TextView headline = text("Not available on this unrooted TV audio path",
                23, TEXT, true);
        LinearLayout.LayoutParams h = new LinearLayout.LayoutParams(-1, -2);
        h.topMargin = dp(20);
        p.addView(headline, h);
        TextView detail = text(explanation, 17, MUTED, false);
        LinearLayout.LayoutParams d = new LinearLayout.LayoutParams(-1, -2);
        d.topMargin = dp(13);
        p.addView(detail, d);
        TextView note = text("Original Timbre feature preserved as a design target; "
                + "no inactive controls are presented as working DSP.", 14, GOLD, false);
        LinearLayout.LayoutParams n = new LinearLayout.LayoutParams(-1, -2);
        n.topMargin = dp(18);
        p.addView(note, n);
    }

    private void applyToService() {
        if (EqSettings.preferences(this).getBoolean(EqSettings.ENABLED, false)) {
            Intent update = new Intent(this, TimbreService.class);
            update.setAction(TimbreService.APPLY);
            startService(update);
        }
    }

    private LinearLayout card() {
        LinearLayout layout = column();
        layout.setBackground(panelBackground(PANEL, BORDER));
        layout.setPadding(dp(20), dp(17), dp(20), dp(17));
        return layout;
    }

    private GradientDrawable panelBackground(int color, int stroke) {
        GradientDrawable d = new GradientDrawable();
        d.setColor(color);
        d.setCornerRadius(dp(15));
        d.setStroke(dp(1), stroke);
        return d;
    }

    private LinearLayout column() {
        LinearLayout l = new LinearLayout(this);
        l.setOrientation(LinearLayout.VERTICAL);
        return l;
    }

    private LinearLayout row() {
        LinearLayout l = new LinearLayout(this);
        l.setOrientation(LinearLayout.HORIZONTAL);
        return l;
    }

    private TextView text(String value, int sp, int color, boolean bold) {
        TextView v = new TextView(this);
        v.setText(value);
        v.setTextColor(color);
        v.setTextSize(sp);
        if (bold) v.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        return v;
    }

    private Button button(String value) {
        Button b = new Button(this);
        b.setText(value);
        b.setTextSize(15);
        b.setAllCaps(false);
        b.setPadding(dp(8), 0, dp(8), 0);
        b.setOnFocusChangeListener((view, hasFocus) -> paintButton(b, false, hasFocus));
        paintButton(b, false, false);
        return b;
    }

    private void paintButton(Button b, boolean selected, boolean focused) {
        if (focused) {
            b.setTextColor(BG);
            b.setBackground(panelBackground(GOLD, GOLD));
        } else if (selected) {
            b.setTextColor(GOLD);
            b.setBackground(panelBackground(DARK_GOLD, GOLD));
        } else {
            b.setTextColor(TEXT);
            b.setBackground(panelBackground(PANEL, BORDER));
        }
    }

    private String frequencyLabel(float frequency) {
        return frequency >= 1000
                ? String.format(Locale.US, "%.0f kHz", frequency / 1000f)
                : String.format(Locale.US, "%.0f Hz", frequency);
    }

    private String gainLabel(int gain) {
        return String.format(Locale.US, "%+d dB", gain);
    }

    private int dp(float v) {
        return (int) (v * getResources().getDisplayMetrics().density + 0.5f);
    }

    private final class CurveView extends View {
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private EqSettings.Curve current = new EqSettings.Curve(
                EqSettings.DEFAULT_FREQUENCIES, new int[]{0, 0, 0, 0, 0});

        CurveView() { super(MainActivity.this); }

        void setCurve(EqSettings.Curve values) {
            current = values;
            invalidate();
        }

        @Override protected void onDraw(Canvas canvas) {
            super.onDraw(canvas);
            float left = dp(39), right = getWidth() - dp(12);
            float top = dp(24), bottom = getHeight() - dp(30);
            if (right <= left || bottom <= top) return;
            float height = bottom - top;
            for (int db = -12; db <= 12; db += 6) {
                float y = top + (12f - db) / 24f * height;
                paint.setColor(db == 0 ? 0xFF8B795D : 0xFF39383A);
                paint.setStrokeWidth(dp(1));
                canvas.drawLine(left, y, right, y, paint);
                paint.setColor(MUTED);
                paint.setTextSize(dp(11));
                canvas.drawText(db > 0 ? "+" + db : Integer.toString(db),
                        dp(4), y + dp(4), paint);
            }
            float[] ticks = {60, 250, 1000, 4000, 12000};
            String[] labels = {"60", "250", "1k", "4k", "12k"};
            for (int i = 0; i < ticks.length; i++) {
                float x = xFor(ticks[i], left, right);
                paint.setColor(0xFF343438);
                canvas.drawLine(x, top, x, bottom, paint);
                paint.setColor(MUTED);
                paint.setTextSize(dp(11));
                canvas.drawText(labels[i], x - dp(11), bottom + dp(21), paint);
            }
            Path line = new Path();
            Path fill = new Path();
            boolean first = true;
            float zero = top + height / 2f;
            for (int px = (int) left; px <= (int) right; px += 2) {
                float f = (float) (20 * Math.pow(1000, (px - left) / (right - left)));
                float gain = EqSettings.gainAt(f, current);
                float y = top + (12f - gain) / 24f * height;
                if (first) {
                    line.moveTo(px, y);
                    fill.moveTo(px, zero);
                    fill.lineTo(px, y);
                    first = false;
                } else {
                    line.lineTo(px, y);
                    fill.lineTo(px, y);
                }
            }
            fill.lineTo(right, zero);
            fill.close();
            paint.setStyle(Paint.Style.FILL);
            paint.setColor(0x44FFB541);
            canvas.drawPath(fill, paint);
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeWidth(dp(3));
            paint.setColor(GOLD);
            canvas.drawPath(line, paint);
            paint.setStyle(Paint.Style.FILL);
            for (int i = 0; i < current.frequencies.length; i++) {
                float x = xFor(current.frequencies[i], left, right);
                float y = top + (12f - current.gains[i]) / 24f * height;
                paint.setColor(PANEL);
                canvas.drawCircle(x, y, dp(7), paint);
                paint.setColor(GOLD);
                canvas.drawCircle(x, y, dp(5), paint);
            }
        }

        private float xFor(float frequency, float left, float right) {
            return (float) (left + Math.log(frequency / 20f) / Math.log(1000)
                    * (right - left));
        }
    }
}

package com.soum91.timbretv;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.SeekBar;
import android.widget.TextView;

import java.util.Locale;

public final class MainActivity extends Activity {
    private final Handler handler = new Handler(Looper.getMainLooper());
    private TextView status;
    private Button power;

    private final Runnable refresh = new Runnable() {
        @Override public void run() {
            boolean enabled = EqSettings.preferences(MainActivity.this)
                    .getBoolean(EqSettings.ENABLED, false);
            power.setText(enabled ? "Stop Timbre TV" : "Start Timbre TV");
            status.setText(EqSettings.preferences(MainActivity.this)
                    .getString(EqSettings.STATUS, "Ready. Enable the service to detect active playback."));
            handler.postDelayed(this, 2000);
        }
    };

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        ScrollView scroll = new ScrollView(this);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        int space = dp(22);
        root.setPadding(space, space, space, space);
        scroll.addView(root);

        TextView title = text("Timbre TV", 30);
        root.addView(title);
        root.addView(text("Experimental Android audio-session EQ for Google TV", 17));

        power = new Button(this);
        power.setText("Start Timbre TV");
        power.setOnClickListener(view -> {
            boolean running = EqSettings.preferences(this).getBoolean(EqSettings.ENABLED, false);
            Intent intent = new Intent(this, TimbreService.class);
            intent.setAction(running ? TimbreService.STOP : TimbreService.START);
            if (running) startService(intent);
            else startForegroundService(intent);
        });
        root.addView(power);

        status = text("Checking service...", 16);
        root.addView(status);
        root.addView(text("Five-band curve, mapped onto the Sony's available Android EQ bands.", 15));

        int[] gains = EqSettings.readGains(this);
        for (int i = 0; i < EqSettings.FREQUENCIES.length; i++) {
            final int index = i;
            TextView label = text("", 18);
            root.addView(label);
            SeekBar seekBar = new SeekBar(this);
            seekBar.setMax(24);
            seekBar.setProgress(gains[index] + 12);
            updateLabel(label, index, gains[index]);
            seekBar.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
                @Override public void onProgressChanged(SeekBar bar, int progress, boolean fromUser) {
                    int gain = progress - 12;
                    updateLabel(label, index, gain);
                    if (fromUser) {
                        EqSettings.saveGain(MainActivity.this, index, gain);
                        if (EqSettings.preferences(MainActivity.this)
                                .getBoolean(EqSettings.ENABLED, false)) {
                            Intent update = new Intent(MainActivity.this, TimbreService.class);
                            update.setAction(TimbreService.APPLY);
                            startService(update);
                        }
                    }
                }
                @Override public void onStartTrackingTouch(SeekBar bar) {}
                @Override public void onStopTrackingTouch(SeekBar bar) {}
            });
            root.addView(seekBar);
        }

        Button flat = new Button(this);
        flat.setText("Reset bands to 0 dB");
        flat.setOnClickListener(view -> {
            for (int i = 0; i < EqSettings.FREQUENCIES.length; i++) EqSettings.saveGain(this, i, 0);
            recreate();
        });
        root.addView(flat);

        root.addView(text("ADB setup (once after install):", 17));
        root.addView(text("adb shell pm grant com.soum91.timbretv android.permission.DUMP", 14));
        root.addView(text("Disable Poweramp Equalizer while testing to avoid competing for the same audio effects.", 15));
        root.addView(text("Limitations: EQ runs only on compatible Android PCM playback sessions. "
                + "Dolby Digital Plus/Atmos passthrough may bypass it. "
                + "This app does not encode Dolby, and the fixed-band engine cannot reproduce "
                + "Timbre's 16-band frequency/Q filters or its native effects chain.", 15));

        setContentView(scroll);
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

    private TextView text(String value, int sp) {
        TextView result = new TextView(this);
        result.setText(value);
        result.setTextSize(sp);
        result.setPadding(0, dp(10), 0, dp(10));
        return result;
    }

    private void updateLabel(TextView view, int index, int gain) {
        view.setText(String.format(Locale.US, "%.0f Hz: %+d dB", EqSettings.FREQUENCIES[index], gain));
    }

    private int dp(int value) {
        return (int) (value * getResources().getDisplayMetrics().density + 0.5f);
    }
}

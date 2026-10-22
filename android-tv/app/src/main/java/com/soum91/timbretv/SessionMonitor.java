package com.soum91.timbretv;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.TimeUnit;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Reads the same AudioPolicy diagnostics verified on the Sony A80L (Android 12). */
final class SessionMonitor {
    private static final Pattern SESSION = Pattern.compile("Session Id: (\\d+) UID: (\\d+)");

    static final class Result {
        final Set<Integer> sessions = new HashSet<>();
        String error;
    }

    private SessionMonitor() {}

    static Result scan() {
        Result result = new Result();
        Process process = null;
        try {
            process = new ProcessBuilder("/system/bin/dumpsys", "media.audio_policy")
                    .redirectErrorStream(true).start();
            StringBuilder output = new StringBuilder();
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(
                    process.getInputStream(), StandardCharsets.UTF_8))) {
                String line;
                while ((line = reader.readLine()) != null) {
                    if (output.length() > 1_000_000) {
                        result.error = "Audio policy dump exceeded safety limit";
                        break;
                    }
                    output.append(line).append('\n');
                }
            }
            if (!process.waitFor(5, TimeUnit.SECONDS)) {
                result.error = "Audio policy dump timed out";
                return result;
            }
            if (process.exitValue() != 0 || output.indexOf("Permission Denial") >= 0) {
                result.error = "Cannot inspect audio sessions. Grant DUMP via ADB.";
                return result;
            }

            boolean active = false;
            int currentSession = 0;
            for (String line : output.toString().split("\\n")) {
                if (line.contains("AudioTrack active (stream) clients:")) {
                    active = true;
                    continue;
                }
                if (!active) continue;
                if (line.contains("Inputs dump:")) break;
                if (line.trim().startsWith("Client ")) currentSession = 0;
                Matcher matcher = SESSION.matcher(line);
                if (matcher.find()) currentSession = Integer.parseInt(matcher.group(1));
                if (currentSession > 0 && (line.contains("Usage: AUDIO_USAGE_MEDIA")
                        || line.contains("Usage: AUDIO_USAGE_GAME"))) {
                    result.sessions.add(currentSession);
                    currentSession = 0;
                }
            }
            if (output.indexOf("AudioTrack active (stream) clients:") < 0) {
                result.error = "This firmware does not expose active AudioTrack clients";
            }
        } catch (Exception e) {
            result.error = "Cannot read AudioPolicy: " + e.getClass().getSimpleName();
        } finally {
            if (process != null) process.destroy();
        }
        return result;
    }
}

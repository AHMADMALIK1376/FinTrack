package pk.fintrack.app;

import android.content.Context;
import android.content.SharedPreferences;

/** Where to send SMS (the user's private FinTrack address), kept in the app's own private storage. */
final class SmsSettings {
    private static final String FILE = "fintrack_sms";

    private SmsSettings() {}

    private static SharedPreferences prefs(Context context) {
        return context.getApplicationContext().getSharedPreferences(FILE, Context.MODE_PRIVATE);
    }

    static String url(Context context) {
        return prefs(context).getString("url", null);
    }

    static void enable(Context context, String url) {
        prefs(context).edit().putString("url", url).remove("last_error").apply();
    }

    static void disable(Context context) {
        prefs(context).edit().clear().apply();
    }

    static void sent(Context context) {
        prefs(context).edit().putLong("last_sent_at", System.currentTimeMillis()).remove("last_error").apply();
    }

    static void error(Context context, String message) {
        prefs(context).edit().putString("last_error", message).apply();
    }

    static long lastSentAt(Context context) {
        return prefs(context).getLong("last_sent_at", 0);
    }

    static String lastError(Context context) {
        return prefs(context).getString("last_error", null);
    }
}

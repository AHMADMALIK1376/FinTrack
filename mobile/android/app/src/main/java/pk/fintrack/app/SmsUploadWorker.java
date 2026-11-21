package pk.fintrack.app;

import android.content.Context;
import androidx.annotation.NonNull;
import androidx.work.BackoffPolicy;
import androidx.work.Constraints;
import androidx.work.Data;
import androidx.work.NetworkType;
import androidx.work.OneTimeWorkRequest;
import androidx.work.WorkManager;
import androidx.work.Worker;
import androidx.work.WorkerParameters;
import java.io.IOException;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.TimeUnit;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Sends one SMS to the user's FinTrack address. Android's WorkManager keeps it until it is sent:
 * it waits for internet, and if the server is asleep (Render's free plan takes up to a minute to
 * wake up) or busy, it tries again later, waiting longer each time. Nothing is lost.
 */
public class SmsUploadWorker extends Worker {
    private static final int MAX_ATTEMPTS = 15;

    public SmsUploadWorker(@NonNull Context context, @NonNull WorkerParameters params) {
        super(context, params);
    }

    static void enqueue(Context context, String sender, String body, long receivedAt) {
        Data data = new Data.Builder()
            .putString("from", sender)
            .putString("text", body)
            .putLong("receivedStamp", receivedAt)
            .build();
        OneTimeWorkRequest request = new OneTimeWorkRequest.Builder(SmsUploadWorker.class)
            .setInputData(data)
            .setConstraints(new Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .build();
        WorkManager.getInstance(context).enqueue(request);
    }

    @NonNull
    @Override
    public Result doWork() {
        Context context = getApplicationContext();
        String url = SmsSettings.url(context);
        if (url == null) {
            return Result.success();   // turned off since: drop it
        }
        if (getRunAttemptCount() >= MAX_ATTEMPTS) {
            SmsSettings.error(context, "Couldn't reach FinTrack for a long time. Some SMS were not sent.");
            return Result.failure();
        }
        HttpURLConnection connection = null;
        try {
            JSONObject json = new JSONObject();
            json.put("from", getInputData().getString("from"));
            json.put("text", getInputData().getString("text"));
            json.put("receivedStamp", getInputData().getLong("receivedStamp", System.currentTimeMillis()));
            byte[] bytes = json.toString().getBytes(StandardCharsets.UTF_8);

            connection = (HttpURLConnection) new URL(url).openConnection();
            connection.setRequestMethod("POST");
            connection.setConnectTimeout(30_000);
            connection.setReadTimeout(90_000);   // the server may be waking up
            connection.setDoOutput(true);
            connection.setRequestProperty("Content-Type", "application/json; charset=utf-8");
            try (OutputStream out = connection.getOutputStream()) {
                out.write(bytes);
            }
            int status = connection.getResponseCode();
            if (status >= 200 && status < 300) {
                SmsSettings.sent(context);
                return Result.success();
            }
            if (status == 404) {
                // the address was replaced or turned off on the website
                SmsSettings.error(context, "Your FinTrack SMS address changed. Turn automatic SMS off and on again.");
                return Result.failure();
            }
            return Result.retry();   // 429 or a server error: later
        } catch (IOException e) {
            return Result.retry();   // no internet, timeout, server asleep
        } catch (JSONException e) {
            return Result.failure();
        } finally {
            if (connection != null) {
                connection.disconnect();
            }
        }
    }
}

package pk.fintrack.app;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.provider.Telephony;
import android.telephony.SmsMessage;

/**
 * Android calls this for every incoming SMS, even when FinTrack is closed (once the user has
 * allowed it). Long messages arrive in parts; they are joined, filtered (SmsFilter) and handed
 * to SmsUploadWorker, which sends them to FinTrack and retries if the phone is offline.
 */
public class SmsReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        if (!Telephony.Sms.Intents.SMS_RECEIVED_ACTION.equals(intent.getAction())) {
            return;
        }
        if (SmsSettings.url(context) == null) {
            return;   // automatic SMS is off
        }
        SmsMessage[] parts = Telephony.Sms.Intents.getMessagesFromIntent(intent);
        if (parts == null || parts.length == 0) {
            return;
        }
        String sender = parts[0].getDisplayOriginatingAddress();
        long receivedAt = parts[0].getTimestampMillis();
        StringBuilder body = new StringBuilder();
        for (SmsMessage part : parts) {
            if (part != null && part.getDisplayMessageBody() != null) {
                body.append(part.getDisplayMessageBody());
            }
        }
        if (SmsFilter.shouldForward(sender, body.toString())) {
            SmsUploadWorker.enqueue(context, sender, body.toString(), receivedAt);
        }
    }
}

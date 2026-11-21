package pk.fintrack.app;

import android.Manifest;
import com.getcapacitor.JSObject;
import com.getcapacitor.PermissionState;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.annotation.Permission;
import com.getcapacitor.annotation.PermissionCallback;

/**
 * What the FinTrack pages can ask the phone (window.Capacitor.Plugins.FinTrackSms):
 *   status()          is automatic SMS on, is the permission given, when was the last SMS sent
 *   enable({ url })   ask Android for the SMS permission (once), then send bank SMS to url
 *   disable()         stop, and forget the address
 */
@CapacitorPlugin(
    name = "FinTrackSms",
    permissions = { @Permission(strings = { Manifest.permission.RECEIVE_SMS }, alias = "sms") }
)
public class FinTrackSmsPlugin extends Plugin {

    @PluginMethod
    public void status(PluginCall call) {
        JSObject result = new JSObject();
        result.put("enabled", SmsSettings.url(getContext()) != null);
        result.put("permission", getPermissionState("sms") == PermissionState.GRANTED);
        long last = SmsSettings.lastSentAt(getContext());
        result.put("lastSentAt", last == 0 ? null : last);
        result.put("lastError", SmsSettings.lastError(getContext()));
        call.resolve(result);
    }

    @PluginMethod
    public void enable(PluginCall call) {
        String url = call.getString("url");
        if (url == null || !url.startsWith("https://") || !url.contains("/api/sms/")) {
            call.reject("That isn't a FinTrack SMS address.");
            return;
        }
        if (getPermissionState("sms") != PermissionState.GRANTED) {
            requestPermissionForAlias("sms", call, "afterPermission");
            return;
        }
        SmsSettings.enable(getContext(), url);
        call.resolve(enabled());
    }

    @PermissionCallback
    private void afterPermission(PluginCall call) {
        if (getPermissionState("sms") != PermissionState.GRANTED) {
            call.reject("SMS permission was not given.", "PERMISSION_DENIED");
            return;
        }
        SmsSettings.enable(getContext(), call.getString("url"));
        call.resolve(enabled());
    }

    @PluginMethod
    public void disable(PluginCall call) {
        SmsSettings.disable(getContext());
        JSObject result = new JSObject();
        result.put("enabled", false);
        call.resolve(result);
    }

    private JSObject enabled() {
        JSObject result = new JSObject();
        result.put("enabled", true);
        return result;
    }
}

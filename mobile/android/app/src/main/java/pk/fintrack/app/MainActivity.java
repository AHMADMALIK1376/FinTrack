package pk.fintrack.app;

import android.os.Bundle;
import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    @Override
    public void onCreate(Bundle savedInstanceState) {
        registerPlugin(FinTrackSmsPlugin.class);   // automatic SMS import (window.Capacitor.Plugins.FinTrackSms)
        super.onCreate(savedInstanceState);
    }
}

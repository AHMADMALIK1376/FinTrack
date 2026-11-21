# FinTrack for Android

The FinTrack pages (`../frontend`) as an Android app made with [Capacitor](https://capacitorjs.com), talking to FinTrack online (`https://fintrack-y4wq.onrender.com`). Inside the app, **SMS import → Turn on automatic SMS** lets the phone send bank, JazzCash and Easypaisa SMS to your review inbox by itself.

## Get the app (no Android Studio needed)

Every pull request builds the app on GitHub. Open the repository's **Actions** tab → the latest **CI** run → **Artifacts** → **FinTrack-android**. Unzip it, copy `app-debug.apk` to your phone and open it. Android asks to allow installing from that source once.

## How automatic SMS works

| Part | File |
|---|---|
| Catches each new SMS, even when the app is closed | `android/app/src/main/java/pk/fintrack/app/SmsReceiver.java` |
| Decides what may leave the phone: only bank and wallet senders (never a person's number), only messages with an amount, never OTPs or PINs | `SmsFilter.java` |
| Sends it to your private FinTrack address; waits for internet and retries while the server wakes up | `SmsUploadWorker.java` (Android WorkManager) |
| The switch the pages call: ask permission, turn on, turn off, status | `FinTrackSmsPlugin.java` |

It uses Android's `RECEIVE_SMS` permission (new messages only; it never reads your inbox). Google Play allows that permission only for a few kinds of apps, so FinTrack is installed from the APK file, not the Play Store.

If Android says the permission is a **restricted setting**, open **Settings → Apps → FinTrack → ⋮ → Allow restricted settings**, then turn automatic SMS on again.

## Build it yourself

You need Node.js 20+, Java 21 and Android Studio (with the Android SDK).

```bash
cd mobile
npm install
npm run sync      # copies ../frontend into www/ (pointed at the server) and updates the Android project
npm run open      # opens Android Studio: Build > Build App Bundle(s) / APK(s) > Build APK(s)
```

For another server: `FT_API_BASE=https://your-fintrack.onrender.com npm run sync` (PowerShell: `$env:FT_API_BASE="https://..."; npm run sync`).

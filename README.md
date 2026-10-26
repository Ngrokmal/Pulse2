# Offline Video Call

Two-way video and audio calls between two Android phones over a local Wi-Fi
hotspot. No internet, account, cloud service or STUN/TURN server is used.

> **Status:** the source in this repository has been written without a
> Flutter SDK, so it has **not been compiled, analysed, tested or run on a
> phone yet**. Build it with the GitHub Actions workflow (or locally) and
> read the results before relying on anything here. See
> `docs/phase5_release_and_testing.md` for what is verified and what is not.

## Use it

1. **Both phones:** turn mobile data off if you want to prove the call is
   offline (Settings, Network, SIM or Mobile data).
2. **Phone A (host):** turn on the Wi-Fi hotspot in Android Settings. The app
   never changes Wi-Fi settings for you.
3. **Phone B:** connect to Phone A's hotspot in Android Settings.
4. **Phone A:** open the app, tap **Host**, then **Start Host**. The screen
   shows its IP address and port, a 6-digit pairing code, and a
   **Show QR code** button.
5. **Phone B:** open the app and tap **Join**, then either
   * **Scan QR code** (recommended): point the camera at Phone A's QR code,
     check the address shown in the dialog, tap **Join**; or
   * type Phone A's IP address, port and 6-digit code and tap **Join**.
6. When both screens say *Connected*, open the **Camera** tab on both phones,
   allow camera and microphone, and tap **Start call** on both.
7. Tap the small quality word (for example *Good*) to open the diagnostics
   panel. Tap **End** to finish. Leaving the call screen releases the camera
   and microphone; **Stop Host** releases the network port.

Use the QR code when you can: it carries a 128-bit secret. The 6-digit code
is a weaker fallback (see `docs/security.md`).

## Android permissions

| Permission | Why |
| --- | --- |
| `INTERNET` | Android needs it for any socket, including local ones. No internet access is used. |
| `ACCESS_NETWORK_STATE`, `CHANGE_NETWORK_STATE` | Listed by the WebRTC plugin for network handling. |
| `CAMERA` | Video call and QR scanning. Asked only when you open the Camera tab or the scanner. |
| `RECORD_AUDIO` | Call audio. Asked when you open the Camera tab. |
| `MODIFY_AUDIO_SETTINGS` | Switching between speaker and earpiece. |

No location, contacts, storage or Bluetooth permission is requested, and the
app has no analytics, ads or cloud telemetry. Video, audio and pairing
secrets are never written to disk.

## Network conditions

Works in principle: both phones on the same hotspot, hotspot allows traffic
between its clients, IPv4. Does **not** work: phones on different networks,
hotspots that isolate clients from each other (the connection times out; try
the other phone as host), VPNs that capture local traffic, IPv6-only
networks. Whether 720p is reached depends on both phones and the signal; the
diagnostics panel shows what really happens. Nothing here has been measured
on real phones yet.

## Troubleshooting

* *Connection timed out / host unreachable:* both phones must use the same
  hotspot; re-check the IP shown on the host; try **Refresh addresses**; try
  the other phone as host.
* *Connection refused:* the host is not running on that port.
* *Wrong pairing code or QR code:* retype the code, or scan again. Five
  failures stop the host; start it again for new credentials.
* *"different protocol version":* install the same APK on both phones.
* *QR scan unavailable:* allow the camera permission (or open app settings if
  it was permanently denied) or join manually.
* *No video but connected:* open the diagnostics panel and read the ICE and
  media lines; some hotspots block phone-to-phone UDP.
* The call can stop when Android puts the app in the background or the phone
  is locked. The screen is kept on only while a call is connected.

## Build and install

The repository contains the full Flutter project (`pubspec.yaml`, `android/`).
CI: run the **Build debug APK** workflow (Actions tab, *Run workflow*); it
checks formatting, analyses, tests and builds, then publishes the `app-debug`
artifact. It also publishes the resolved `pubspec-lock` artifact: commit that
file to the repository root once, so later builds use exactly those versions.

Locally (Flutter 3.35.x stable, Java 17):

    flutter pub get
    dart format lib test
    flutter analyze
    flutter test
    flutter build apk --debug
    adb install -r build/app/outputs/flutter-apk/app-debug.apk

Release build and signing: `docs/phase5_release_and_testing.md`. The workflow
builds the debug APK only.

## More

* `docs/security.md` — what the pairing protects and what it does not.
* `docs/phase5_release_and_testing.md` — release steps, two-phone checklist
  (every item currently *not performed*).
* `docs/phase4_performance.md`, `docs/phase3_webrtc.md`,
  `docs/phase2_networking.md` — earlier phases.

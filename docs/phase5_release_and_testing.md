# Phase 5: security, QR pairing, release readiness and test status

> **Update (build repair):** the repository now contains `pubspec.yaml`,
> `analysis_options.yaml` and a complete `android/` project, and the workflow
> no longer runs `flutter create` or `flutter pub add`. Where this document
> mentions a CI-generated scaffold, dependencies added by CI, or a release
> build step, read it as superseded: CI builds the debug APK only, with the
> application ID `com.example.offline_video_call`. Release signing is still
> the manual task described below. Nothing has been compiled by the author of
> this repair either; the first GitHub Actions run is the first real build.


**Nothing in this document has been run on a computer with Flutter or on a
phone.** The environment that produced this code had no Flutter/Dart SDK and
no network, and the repository snapshot has no `pubspec.yaml` or `android/`
folder. There is no APK from this work. Every result below that needs a
compiler or a phone is marked accordingly.

## 1. Repository audit (what was actually found)

* No `.git` directory in the uploaded snapshot, so no Git status or
  uncommitted-change check was possible.
* No `pubspec.yaml`, `android/`, icon or splash assets in the snapshot. The CI
  workflow creates a scaffold (`flutter create --empty --org com.example
  --project-name offline_video_call`) and adds dependencies, so the Flutter,
  Dart, Gradle, Kotlin, SDK and package versions are whatever "stable" resolves
  to on the day. The CI log prints them.
* Phase 2 handshake sent the 6-digit pairing code in clear text; the host
  bound `0.0.0.0` and accepted any source address and any `Origin`; the
  lockout (5 wrong codes) and one-peer rule existed. Message validation,
  size limit, session/sender checks existed and were kept.
* Phase 3 negotiation and Phase 4 diagnostics/adaptation are present
  (Phase 4 uncompiled).
* Baseline checks (`flutter analyze`, `flutter test`) could not be run.

## 2. What changed in Phase 5

| Area | Change |
| --- | --- |
| Handshake | Protocol v2: mutual HMAC challenge-response, credential never sent (`models/handshake_auth.dart`, `services/local_signal_service.dart`). Needs the `crypto` package. |
| Credentials | 128-bit session secret plus 6-digit code, from `Random.secure()`. |
| Host filters | Refuse non-private source addresses and requests with an `Origin` header. |
| QR pairing | Host shows a QR (`widgets/host_qr_card.dart`, package `qr_flutter`); joiner scans (`qr_scan_screen.dart`, package `mobile_scanner`), payload parsed strictly (`models/pairing_payload.dart`), user confirms the address, then joins. Manual entry unchanged. |
| Camera hand-over | `LocalMediaService.stop()` frees the camera for the scanner (not allowed during a call). |
| Screen on | `services/call_wakelock.dart` (`wakelock_plus`) keeps the screen on while connected; no permission needed. |
| UI | Mic/camera "off" buttons drawn in error colours; diagnostics panel capped at a quarter of the screen height; scan button disabled during a call; limitations text corrected. |
| CI | New dependencies, app label "Offline Video Call", release build with signer printout. |

## 3. Tests added or changed

New: `handshake_auth_test` (MAC, tokens, QR payload, address checks),
`signaling_security_test` (real loopback sockets: wrong/replayed/cross-mode
proofs, impostor host, secret not on the wire, Origin refusal, second peer,
handshake timeout, lockout, cleanup), `ui_state_test` (widget tests for the
quality badge, diagnostics panel, call controls, connection panel, QR card),
`support/raw_client.dart`. Changed: `call_signaling_loopback_test` (uses the
v2 handshake). Earlier Phase 4 tests unchanged.

These use fake data and loopback sockets. **They have not been run.** Passing
them would not prove two-phone connectivity or security against every attack.

## 4. Release readiness

* **Application ID:** the CI scaffold gives `com.example.offline_video_call`,
  an example namespace. Decide the real ID **before** anyone installs a build
  you want to keep: changing it later installs as a different app and loses the
  old app's data. If you already have an ID, keep it in your own `android/`
  folder; this repository does not contain it.
* **Version:** set `version: 1.0.0+1` (name+code) in `pubspec.yaml`; raise the
  code for every build you distribute.
* **Label:** CI sets "Offline Video Call". **Launcher icon:** still the default
  Flutter icon (pending; a custom icon needs your artwork).
* **SDK levels:** from the Flutter defaults; CI prints `minSdk`/`targetSdk`.
  `mobile_scanner` or `flutter_webrtc` may require a higher `minSdk` than the
  default; if the build says so, set `minSdk` in `android/app/build.gradle(.kts)`.
* **Permissions:** see README. `CHANGE_NETWORK_STATE`/`ACCESS_NETWORK_STATE`
  are listed by the WebRTC plugin documentation and were not removed.
* **Debug behaviour:** `debugPrint` is used in a few places and prints only
  exception type names, never secrets or SDP. It also prints in release.
* **Signing:** the generated scaffold signs `--release` with the **debug**
  key. That file is installable but is **not production-signed**. CI prints the
  signer so you can see this. No keystore or password is in this repository.

### Make a properly signed release (you must do this)

1. Create a keystore once and keep it and its passwords somewhere safe (if you
   lose it you cannot update the app):

       keytool -genkey -v -keystore ~/keys/offline-video-call.jks \
         -keyalg RSA -keysize 2048 -validity 10000 -alias upload

2. Copy `docs/key.properties.example` to `android/key.properties`, fill in
   your values. Both the file and the `.jks` are git-ignored.
3. In `android/app/build.gradle.kts` (Kotlin DSL; Groovy `build.gradle` is
   analogous) read the file and use it for `release`:

       import java.util.Properties
       import java.io.FileInputStream

       val keystoreProperties = Properties()
       val keystorePropertiesFile = rootProject.file("key.properties")
       if (keystorePropertiesFile.exists()) {
           keystoreProperties.load(FileInputStream(keystorePropertiesFile))
       }

       android {
           signingConfigs {
               create("release") {
                   keyAlias = keystoreProperties["keyAlias"] as String
                   keyPassword = keystoreProperties["keyPassword"] as String
                   storeFile = file(keystoreProperties["storeFile"] as String)
                   storePassword = keystoreProperties["storePassword"] as String
               }
           }
           buildTypes {
               release {
                   signingConfig = signingConfigs.getByName("release")
               }
           }
       }

4. Build and check who signed it:

       flutter build apk --release
       apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk

   The certificate must be yours, not "Android Debug".

## 5. Build results

| Command | Result |
| --- | --- |
| `flutter pub get` | NOT RUN |
| `dart format` | NOT RUN (CI formats `lib test` on its own copy) |
| `flutter analyze` | NOT RUN |
| `flutter test` | NOT RUN |
| `flutter build apk --debug` | NOT RUN, no APK exists |
| `flutter build apk --release` | NOT RUN; would be debug-signed until step 4 above is done |

First things to check in the first CI log: resolved package versions;
`mobile_scanner` and `qr_flutter` API names (`MobileScanner`,
`MobileScannerController`, `BarcodeCapture`, `QrImageView`); `minSdk`;
`StatsReport.id`, `RTCRtpSender.setParameters` (Phase 4).

## 6. Two-phone checklist

Status of **every** item: **NOT PERFORMED** (no phones were available). Fill
in passed / failed / blocked yourself; do not assume.

| # | Test | Expected | Status |
| --- | --- | --- | --- |
| 1 | Mobile data off on both phones | Call still works | NOT PERFORMED |
| 2 | Hotspot on Phone A | Phone A shows an address like 192.168.x.1 | NOT PERFORMED |
| 3 | Phone B joins the hotspot | Wi-Fi connected, no internet warning is fine | NOT PERFORMED |
| 4 | Host mode on A | Address, port, code, Show QR button | NOT PERFORMED |
| 5 | Manual join on B | Both show Connected | NOT PERFORMED |
| 6 | QR join on B | Dialog shows A's address; after Join both Connected | NOT PERFORMED |
| 7 | Two-way video and audio | Both see and hear each other | NOT PERFORMED |
| 8 | Mute/unmute, camera off/on | Other side hears silence / sees black; buttons look "off" | NOT PERFORMED |
| 9 | Flip front/rear camera repeatedly | Call stays up | NOT PERFORMED |
| 10 | Wrong code; wrong secret (scan another host's QR) | Error, host keeps listening; 5 failures stop host | NOT PERFORMED |
| 11 | Scan a QR that is not ours / other version | Message, scanning continues, nothing connects | NOT PERFORMED |
| 12 | Join a different host (other session) with this host's QR | Refused | NOT PERFORMED |
| 13 | End and restart the call 10 times | No stuck state, no crash | NOT PERFORMED |
| 14 | Turn Wi-Fi off/on on B for 3 s | "Reconnecting", then recover or clear failure | NOT PERFORMED |
| 15 | Background and resume for 10 s | Note what resumes | NOT PERFORMED |
| 16 | 30-minute call | Stable; note drift in memory/heat | NOT PERFORMED |
| 17 | After End: camera/mic indicators, stop host | Port freed; indicators off after leaving the screen | NOT PERFORMED |
| 18 | Airplane mode + hotspot only (no SIM/internet) | Works | NOT PERFORMED |
| 19 | Deny camera permission at the scanner (and "don't ask again") | Explanation, manual join still works | NOT PERFORMED |
| 20 | Cancel the scan (back button) | Nothing connects | NOT PERFORMED |
| 21 | Screen timeout during a call | Screen stays on while connected | NOT PERFORMED |
| 22 | Small phone (about 5 inch): call screen, diagnostics open | Controls stay reachable | NOT PERFORMED |
| 23 | Install the debug APK over an existing install | Updates in place | NOT PERFORMED |

Commands for the two phones (USB debugging on, `adb` installed):

    adb devices
    adb -s <phoneA-serial> install -r app-debug.apk
    adb -s <phoneB-serial> install -r app-debug.apk
    adb -s <phoneA-serial> logcat -s flutter

## 7. Remaining limits and risks

* Nothing compiled or executed; expect first-build fixes.
* Protocol v2 is incompatible with earlier builds (same APK on both phones).
* Signaling is unencrypted and post-handshake messages are not authenticated
  (`docs/security.md`).
* Four new dependencies (`crypto`, `qr_flutter`, `mobile_scanner`,
  `wakelock_plus`), resolved to whatever is newest on the build day and not
  compatibility-checked here.
* Camera/microphone stay open after a call while the call screen is open
  (Phase 1 preview design); the scanner frees them first.
* No foreground service: Android may stop camera and microphone when the app
  is in the background or the phone is locked. Uninterrupted calls are not
  promised.
* ICE restart / renegotiation after a Wi-Fi loss is not implemented
  (`docs/phase4_performance.md`).
* Signing, application ID decision and launcher icon remain for you.

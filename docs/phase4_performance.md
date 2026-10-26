# Phase 4: performance measurement, call quality and conservative adaptation

Status: **implemented in source, NOT compiled, NOT run, NOT tested on phones.**
The sandbox used for this work had no Flutter/Dart SDK and no network, and the
repository snapshot contains no `pubspec.yaml` or `android/` folder (the CI
workflow creates them). So `flutter pub get`, `dart format`, `flutter analyze`,
`flutter test` and `flutter build apk --debug` have not been run, and there is
no APK. Phase 3 had the same status. Read the first CI log before trusting any
of this.

## 1. Findings in the existing code (read from source)

* Local tracks are created once (`LocalMediaService`) and added once per call;
  no duplicate microphone or camera tracks.
* One poller existed (2 s, busy-guarded) but only produced cumulative
  counters: no bitrate, loss, jitter, RTT, candidate pair, encoder name.
* Sender limits (2500 kbit/s, 30 fps) were set once through
  `RTCRtpSender.setParameters`; nothing could change them later.
* The "Start call" path had no re-entrancy guard of its own (the negotiator
  was protected, the service was not); the speaker toggle had none either.
* The speaker state was assumed `true` even if routing failed.
* The statistics timer ran while the app was in the background.
* `_onConnected` ran twice per connection (ICE state and peer state) and each
  run requested an extra immediate stats read.
* Signaling loss ends the call; there is no renegotiation (Phase 3 design).
* The camera/microphone stream stays open after a call ends while the call
  screen is open (Phase 1 preview design). It is released when the screen
  closes. Not changed, see risks.
* Not verified (needs a device): hardware vs software encoding, rebuild cost
  of the camera tab. The diagnostics panel now shows the encoder and decoder
  names so this can be read off a real call.

## 2. What changed

New files

| File | Purpose |
| --- | --- |
| `models/call_stats.dart` | Parses `getStats` into a nullable sample; computes rates from counter differences |
| `models/call_quality.dart` | Quality states, configurable thresholds, hysteresis |
| `models/bitrate_adaptation.dart` | Step ladder, cooldowns, up/down rules (pure logic) |
| `models/diagnostics_format.dart` | Text formatting; unavailable values show a dash |
| `services/stats_poller.dart` | Single non-overlapping, stoppable timer |
| `services/call_stats_service.dart` | Diagnostics service: metrics, quality, adaptation, notifiers |
| `presentation/widgets/call_quality_badge.dart` | Small indicator in the status row |
| `presentation/widgets/diagnostics_panel.dart` | Optional panel (tap the indicator) |
| tests | `call_stats_test`, `call_quality_test`, `bitrate_adaptation_test`, `stats_poller_test`, `call_stats_service_test` |

Edited: `call_state.dart` (`RawStat.id`), `flutter_webrtc_peer_link.dart`
(poller, raw stats callback, `applyVideoLimits`, pause/resume, speaker result),
`call_negotiator.dart` (`isReconnecting` getter only), `webrtc_service.dart`
(stats wiring, start/speaker guards, lifecycle), `call_screen.dart`,
`call_status_panel.dart`, and `call_negotiator_test.dart` (new group; `Pair`
accepts `disconnectGrace`).

## 3. Statistics the app reads (when the platform reports them)

Outbound/inbound video size, frame rate, bitrate (byte-counter difference over
elapsed time), codec, encoder/decoder implementation name, encoder
`qualityLimitationReason`; audio bitrate; inbound loss per interval (video and
audio); outbound loss as reported by the other phone (RTCP); jitter; RTT
(selected candidate pair, else RTCP); selected pair local/remote candidate
type, protocol, network type (no IP addresses); bytes sent/received; available
outgoing bitrate. A missing field is `null` and shown as a dash, never 0.
Invalid intervals (first sample, zero or negative time step, gap over 10 s,
counter going backwards, no packets in the interval) give "unavailable".
Sampling interval: 2 s (unchanged), one poll shared by everything.

## 4. Quality indicator

States: Connecting, Good, Fair, Poor, Reconnecting, Disconnected. Connection
events override measurements. Thresholds (engineering starting points, **not
validated**, all constructor parameters in `QualityThresholds`):
fair at loss >= 2 %, RTT >= 150 ms, jitter >= 30 ms; poor at loss >= 8 %,
RTT >= 400 ms, jitter >= 100 ms. Worsening needs 3 consecutive worse samples,
improving needs 5; a streak moves only as far as its mildest (or worst-of-
better) sample. Three consecutive valid intervals without any received media
byte show a stall and "Poor" at once. An encoder limited by `cpu` is reported
as a device limit and does not lower the network grade; `bandwidth` counts as
fair.

## 5. Adaptation: what it does and does not do

* Only the **maximum bitrate and maximum frame rate** of the video sender are
  changed, through `RTCRtpSender.setParameters` (the same call Phase 3 already
  used). Ladder: 2500 kbit/s 30 fps (normal) -> 1500/30 -> 900/24 -> 500/15.
* Trigger: the outgoing-path evaluator (loss reported by the other phone, RTT,
  encoder limitation) must be **poor with a network cause** for 3 consecutive
  samples. Cooldown 10 s between reductions. Relaxing needs 8 consecutive good
  reports and 30 s since the last change, one step at a time. A refused change
  is undone; two refusals switch adaptation off for the call.
* **Not done:** setting a start bitrate (no supported parameter; libwebrtc's
  own estimator picks it), changing capture resolution or camera frame rate on
  a running stream, scaling resolution, forcing a codec. libwebrtc's own
  congestion control keeps running underneath; this layer only lowers its cap.
  Whether the installed `flutter_webrtc` honours `maxBitrate`/`maxFramerate`
  on Android must be confirmed on a device by watching the measured send
  bitrate in the panel after a step.
* Because the call goes over a local hotspot, the first measurements may show
  the cap is rarely reached; that is expected.

## 6. Connection stability

Unchanged: local-only ICE (no STUN/TURN), 30 s connect timeout, 8 s
disconnect grace, signaling loss ends the call. New: "Reconnecting" is shown
during the grace period; media stalls are detected; the statistics timer stops
when the call ends and while the app is in the background; repeated Start,
Accept, Speaker, hang-up and dispose are guarded.

**ICE restart was deliberately not implemented.** It needs a second
offer/answer round (the negotiator currently refuses a second offer by
design), and the exact flutter_webrtc API (`restartIce`, offer constraints)
could not be checked without the package source. Also, a real Wi-Fi outage
drops the signaling WebSocket too, which ends the call before a restart could
be signalled. Recovery after an outage is therefore "start the call again".

## 7. Audio

No change to capture constraints: the stream is requested with `audio: true`,
so whatever echo cancellation / noise suppression the native stack applies by
default is used. The app does not claim or verify that any of them is active.
Camera on/off touches only video tracks; mute touches only audio tracks; one
audio track per call. The speaker button now reflects whether routing really
succeeded when the call opened. Earpiece/speaker routing relies on
`Helper.setSpeakerphoneOn`.

## 8. Commands to run (CI does these; none were run here)

    flutter pub get
    dart format lib test
    flutter analyze
    flutter test
    flutter build apk --debug

Expected first-build risks: Phase 3 and Phase 4 code was written without a
compiler. API names to check first: `StatsReport.id`, `RTCRtpSender.parameters`
/ `setParameters`, `RTCRtpEncoding` fields, `Helper.setSpeakerphoneOn`.

## 9. Manual two-phone test (NOT performed)

1. Install the same debug APK on both phones. Phone A: hotspot on. Phone B:
   join it. Mobile data off on both.
2. A: Host. B: Join (IP, port, code). Both: Camera tab, allow permissions,
   Start call.
3. Open the panel by tapping the quality word. Record, for both phones:
   sending/receiving size and fps, bitrate, encoder and decoder names, loss,
   RTT, jitter, path type. Note any dash values.
4. Strong signal, 2 min: expect Good. Check the panel numbers against the
   picture. Weak signal (walk away, or put one phone in a bag): watch Fair or
   Poor, and whether "Send limit" steps down; after returning, steps up only
   after about 30 s of Good.
5. Mute/unmute (other phone hears silence/speech), camera off/on (audio must
   continue), flip camera several times (call must stay up, size/fps may
   change), speaker/earpiece.
6. Press End, start again, repeat 10 times: no stuck "Starting" state, no
   crash, memory stable.
7. Turn the hotspot Wi-Fi off for 3 s on phone B and on again: expect
   "Reconnecting", then either recovery or a clear failure message. Longer
   outage: call ends, Host stays up.
8. Background the app for 10 s mid-call and return: note whether video and
   audio resume (Android may stop camera/mic in the background; no foreground
   service exists).

## 10. Known limits and risks

* Nothing compiled or run; thresholds and ladder untuned.
* Camera/microphone stay open after a call while the screen is open.
* No foreground service: backgrounding can stop capture.
* `MediaSnapshot` milestones still use cumulative counters, so after a
  disconnect the "Video frames" chip can stay on without new frames.
* Ladder step 0 must equal `CallVideoSettings` (both 2500/30 by default).

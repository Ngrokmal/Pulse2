# Phase 3: real WebRTC video and audio over the hotspot

Status: **implemented in source, not yet compiled or run.** The sandbox this
work was done in has no Flutter/Dart SDK and no network, so `flutter analyze`,
`flutter test` and `flutter build apk` have NOT been run on this code. The CI
workflow (`.github/workflows/build.yml`) runs them; read its log first.

## Architecture

| Concern | File |
| --- | --- |
| Signaling transport (Phase 2, extended) | `services/local_signal_service.dart` |
| Message envelope + new types | `models/signal_message.dart` |
| SDP / ICE payload validation | `models/call_signal.dart` |
| Roles, phases, milestones, candidate queue, stats parser | `models/call_state.dart` |
| Negotiation logic (no native code, unit-tested) | `services/call_negotiator.dart` |
| Native peer connection (flutter_webrtc) | `services/flutter_webrtc_peer_link.dart` |
| What the UI uses; renderer + duration | `services/webrtc_service.dart` |
| Camera / microphone (Phase 1, reused) | `services/local_media_service.dart` |

The camera is opened once by `LocalMediaService`. The same tracks are used for
the local preview and are added to the peer connection. `WebRtcService` never
stops them.

## Protocol additions (same envelope: `v`, `type`, `session`, `sender`, `payload`)

| type | payload |
| --- | --- |
| `call_ready` | `{"audio":true,"video":true}` |
| `offer` / `answer` | `{"type":"offer"\|"answer","sdp":"v=0..."}` (max 14 KB) |
| `candidate` | `{"candidate":"candidate:...","sdpMid":"0","sdpMLineIndex":0}`; empty `candidate` = end |
| `call_reject` | `{"reason":"declined"}` |
| `call_end` | `{"reason":"hangup"}` |
| `error` | `{"code":"...","message":"..."}` (codes: `negotiation_out_of_order`, `call_not_ready`, `wrong_negotiation_role`, `invalid_sdp`, `invalid_candidate`) |

Call messages are only delivered after the Phase 2 handshake, and only when
the session id and sender id match (otherwise `session_mismatch`). The 16 KB
Phase 2 message limit still applies; an SDP that would exceed it is refused
before sending and the call fails with a clear message.

## Negotiation

1. Both phones are connected through Phase 2 signaling.
2. On **Start call** (or **Accept call**) each phone starts the camera and
   microphone (permissions), creates the peer connection, adds the local tracks
   and sends `call_ready`.
3. The **Host is always the offerer**; the joined phone is the answerer.
4. The Host creates the offer only after it is ready itself **and** has
   received the other phone's `call_ready`. The answerer never offers, so
   there is no glare.
5. Host: `createOffer` -> `setLocalDescription` -> send `offer`.
   Joined phone: `setRemoteDescription(offer)` -> `createAnswer` ->
   `setLocalDescription` -> send `answer`. Host: `setRemoteDescription(answer)`.
6. Local ICE candidates are held until the offer/answer they belong to has been
   sent, then sent as `candidate` messages. Remote candidates that arrive
   before the remote description are queued and applied right after it.
7. Messages are processed one at a time, in order. Out-of-order, duplicate or
   wrong-role messages get an `error` reply and are ignored.
8. A 30 s timer fails the call if ICE does not connect.

ICE configuration: `{'iceServers': [], 'sdpSemantics': 'unified-plan'}`. No STUN,
no TURN, no fallback relay.

## What "connected" means in the UI

Milestones are shown separately and each needs its own evidence:

- Signaling: Phase 2 WebSocket connected.
- Negotiated: offer and answer installed.
- ICE connected: ICE / peer connection state reported connected.
- Remote track: `onTrack` fired.
- Video frames: `getStats()` shows `framesDecoded` > 0 on the inbound video.
- Audio bytes: `getStats()` shows inbound audio `bytesReceived` > 0.

The call phase becomes "call is running" only after video frames are decoded.
Statistics are polled every 2 s; the panel also shows the received and sent
resolution and frame rate reported by WebRTC, and the number of local/remote
candidates (no addresses).

## Media settings

Capture: 1280x720 at 30 fps requested (`LocalMediaService` constructor
parameters). The camera and encoder may deliver less; read the real values in
the status panel. After ICE connects, the video sender is limited to
2500 kbit/s and 30 fps via `RTCRtpSender.setParameters` (`CallVideoSettings`).
If the platform refuses, the encoder keeps its defaults (a debug log line says
so). Codecs are not forced; the native stack chooses. No adaptive bitrate logic
was added.

Audio is routed to the loudspeaker with `Helper.setSpeakerphoneOn`; the
Speaker/Earpiece button toggles it. No other audio-session API is used.

## Privacy

Nothing is recorded, uploaded or stored. No telemetry. SDP and ICE candidates
are never logged (they contain private addresses). WebRTC media is encrypted
(DTLS-SRTP), but the signaling channel is plain `ws://`: anyone on the hotspot
can read the pairing code and the SDP/candidates, and could try to impersonate
a phone. The pairing code and session check from Phase 2 are unchanged.

## Two-phone test (not yet performed)

1. Install the same debug APK on both phones.
2. Phone A: turn on the hotspot. Phone B: join it. Turn mobile data off on both.
3. Phone A: **Host** -> **Start Host**. Phone B: **Join**, enter IP, port, code.
4. Both: open the **Camera** tab and allow camera and microphone.
5. Tap **Start call** on both (the other phone first shows "ready" /
   **Accept call** if it has not tapped yet).
6. Expect the six chips to turn on in order. Check each phone shows the other
   phone's video and that the resolution/fps line looks plausible.
7. Talk on each phone; check the other phone hears it (speaker on).
8. Test Mute, Camera off/on (the call must stay up), Flip camera, Speaker.
9. Tap End on one phone: both must return to "ended" and the Host must still
   be running (Connection tab) so a new call can be started.
10. Failure checks: turn the hotspot off mid-call; try a wrong pairing code;
    try two different phone brands as host.

## Known limits

- Some hotspots isolate clients, or the hotspot interface may not yield usable
  candidates on some Android versions. Then ICE fails and the app says so
  (with candidate counts). Try the other phone as host.
- If the WebSocket signaling drops, the call is stopped (no renewed
  negotiation, no reconnection).
- The remote phone is not told when the other side turns its camera off; it
  just sees a black frame.
- Backgrounding the app can drop signaling or pause the camera.
- Nothing here was compiled; flutter_webrtc API names used (`Helper`,
  `RTCRtpSender.parameters/setParameters`, `RTCPeerConnection.dispose`,
  `getStats`) were written from memory of the 1.x API and must be confirmed by
  the CI build.

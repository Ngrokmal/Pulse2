# Phase 2: local hotspot networking

Two phones talk over a local Wi-Fi hotspot. No internet, no cloud service.
Phase 2 itself only exchanged test messages and ping/pong.
WebRTC calling was added in Phase 3: see `phase3_webrtc.md`.

## How to test (two physical Android phones, mobile data off)
1. Phone A: turn on the Wi-Fi hotspot in Android Settings.
2. Phone B: join that hotspot in Android Settings (it will say "no internet"; that is fine).
3. Both phones: open the app. Phone A taps **Host**, then **Start Host**.
4. Phone A shows IP address(es), port and a 6-digit pairing code.
5. Phone B taps **Join** and enters the IP, port and pairing code, then **Join**.
6. Both phones show "Connected". Send test messages both ways and tap the ping button.

## Protocol (JSON over `ws://HOST_IP:PORT/signal`)
`{"v":1,"type":"hello|hello_ack|ping|pong|chat|error","session":"...","sender":"...","payload":{...}}`
- Client sends `hello` with the pairing code; host answers `hello_ack` with the session id.
- Messages over 16 KB, malformed JSON, unknown types and other protocol versions are rejected.
- One peer at a time. A second phone gets `host_busy`. Five wrong codes stop the host.

## Android notes
- Needs `INTERNET` (local sockets). No location, Wi-Fi-state or local-network permission is requested.
- Android 17 enforces `ACCESS_LOCAL_NETWORK` only for apps whose **targetSdk is 37 or higher**.
  This project uses Flutter's default target SDK; the CI log prints the real value.
  If you raise targetSdk to 37+, add that permission and request it at runtime (not implemented).
- The host binds to all IPv4 interfaces because the hotspot interface address differs per phone.
- Plain `dart:io` sockets are not covered by Android's cleartext-HTTP policy; this is expected
  to work but is **unverified until tested on real phones**.

## Limitations
- The hotspot IP is not always 192.168.43.1. Interface labels in the app are guesses.
- Some phones block traffic between hotspot clients (AP isolation).
- `ws://` is not encrypted: pairing code and messages can be read by others on the hotspot.
- Dart cannot cap a WebSocket frame before it is received; oversize messages are rejected after receipt.
- The connection may drop when the app is in the background.
- Loopback tests (`flutter test`) prove the protocol logic only, not real hotspot communication.

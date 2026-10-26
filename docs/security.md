# Security properties and limitations

Scope: the local signaling channel (`ws://` between the two phones) and the
pairing that decides who may join a host. Written from reading the source;
**no penetration test or independent review has been done.**

## What a joining phone must prove

The host creates, per host session, with `Random.secure()`:

* a **session secret**: 16 random bytes (128 bits), shown only inside the QR
  code on the host screen;
* a **pairing code**: 6 random digits, shown on the host screen for manual
  entry;
* a session id (an identifier, not a secret).

Protocol version 2 replaced the old handshake that sent the code in clear
text. Now:

1. Joiner -> host `hello`: which credential it will use (`secret` or `code`)
   and a fresh random nonce.
2. Host -> joiner `hello_challenge`: the host's fresh nonce and the session id.
3. Joiner -> host `hello_proof`: HMAC-SHA256 over both nonces, both sender
   ids and the session id, keyed with the credential.
4. Host checks it in constant time, then replies `hello_ack` with its own
   HMAC (different label), so the joiner knows it reached a host that knows
   the credential.

The credential itself is never sent. A proof cannot be replayed on another
connection (fresh nonces), and a rogue host that does not know the credential
cannot produce the host proof. The QR secret is never typed or sent; it only
exists on the host screen, in the scanned image and in memory.

## Other protections in place

* One peer at a time. A second socket is refused (`host_busy`), also while
  the first is still in its handshake. A handshake that does not finish in 5 s
  is dropped.
* Five failed proofs stop the host and wipe its credentials; starting again
  creates new ones.
* The host refuses connections whose source address is not a private LAN
  address (10/8, 172.16/12, 192.168/16, 169.254/16) or this phone itself, so
  a mobile-data address cannot be used to reach it even though the server
  listens on all IPv4 interfaces.
* Requests with an `Origin` header (web pages in a browser) are refused.
* Every message is validated: text only, at most 16 KB, JSON object, version,
  known type, id lengths, payload shape. After the handshake, messages with a
  different session or sender id are refused and never delivered to the call
  logic. Call messages before the handshake are refused.
* QR text is parsed strictly (version, private IPv4 only, port 1024-65535,
  32 lowercase hex secret, at most 128 characters). The app only fills the
  form and always asks the user to confirm the address before connecting.
* Secrets are not logged. Error messages and the scanner never repeat scanned
  text. Pairing data is kept in memory only (a joiner keeps it until you leave
  the screen, so **Retry** works).

## Known limitations (read these)

1. **The signaling channel is not encrypted.** Anyone who can see traffic on
   the hotspot can read call setup (SDP, ICE candidates with phone addresses)
   and chat test messages. WebRTC media itself is encrypted (DTLS-SRTP).
2. **Messages after the handshake are not individually authenticated.** An
   attacker who can modify the TCP stream (an active man in the middle on the
   hotspot, or someone who can inject into the established connection) could
   alter the SDP, including the media key fingerprint. Hotspot membership
   (WPA2/WPA3 password) is the only barrier against that.
3. **The 6-digit code is weak against offline guessing.** Someone who records
   a handshake can try all 1,000,000 codes quickly. Online guessing is limited
   to 5 tries per host session. Use the QR secret when the network is shared
   with people you do not trust.
4. **The QR code is a bearer secret for the whole host session.** Anyone who
   photographs it can join until the host is stopped (unless a phone is
   already connected). Hide it when not needed; it is hidden once a phone has
   connected.
5. **Denial of service is possible on a shared network.** A device on the
   hotspot can hold the single slot during the handshake window, or cause five
   failed proofs to stop the host.
6. `dart:io` WebSocket buffers a whole incoming message before the 16 KB check
   can run, so very large frames cost memory first.
7. Protocol version 2 is **not compatible** with the earlier builds. Install
   the same APK on both phones.
8. A phone's own hotspot password and Android's client isolation are outside
   this app.
9. The app does not hide the camera or microphone from the user: Android's
   indicators show when they are active.

Nothing here makes the app "fully secure". It is a prototype for use between
two phones you control, on a network you trust.

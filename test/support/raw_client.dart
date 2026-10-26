// A hand-written signaling client for tests. It speaks the v2 handshake
// directly on a WebSocket, so tests can send deliberately wrong proofs,
// replay frames, or skip steps, which the real service never does.
// ignore_for_file: avoid_relative_lib_imports
import 'dart:async';
import 'dart:io';

import '../../lib/features/video_call/models/handshake_auth.dart';
import '../../lib/features/video_call/models/session_tokens.dart';
import '../../lib/features/video_call/models/signal_message.dart';
import '../../lib/features/video_call/services/local_signal_service.dart';

class RawClient {
  RawClient._(this.socket, this.senderId);

  final WebSocket socket;
  final String senderId;
  final List<SignalMessage> received = <SignalMessage>[];
  final List<Object?> rawFrames = <Object?>[];
  bool closed = false;

  static Future<RawClient> connect(
    int port, {
    Map<String, dynamic>? headers,
    String senderId = 'raw-client',
  }) async {
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:$port${LocalSignalService.signalPath}',
      headers: headers,
    );
    final client = RawClient._(socket, senderId);
    socket.listen(
      (Object? data) {
        client.rawFrames.add(data);
        try {
          client.received.add(SignalMessage.decode(data));
        } on SignalFormatException {
          // Not a valid message; keep the raw frame only.
        }
      },
      onDone: () => client.closed = true,
      onError: (Object _) => client.closed = true,
    );
    return client;
  }

  void send(
    SignalType type,
    Map<String, Object?> payload, {
    String session = '',
  }) {
    socket.add(
      SignalMessage(
        type: type,
        sessionId: session,
        senderId: senderId,
        payload: payload,
      ).encode(),
    );
  }

  Future<SignalMessage> waitFor(
    bool Function(SignalMessage message) test, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      for (final message in received) {
        if (test(message)) return message;
      }
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('No matching message arrived.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<SignalMessage> waitForType(SignalType type) =>
      waitFor((m) => m.type == type);

  /// Runs the whole handshake. Returns `hello_ack`, or the `error` the
  /// host answered with. [proofCredential] lets a test prove a different
  /// credential than the one named in `hello`.
  Future<SignalMessage> handshake(
    CredentialMode mode,
    String credential, {
    String? proofCredential,
  }) async {
    final clientNonce = generateNonce();
    send(SignalType.hello, <String, Object?>{
      'mode': mode.wireName,
      'cn': clientNonce,
    });
    final challenge = await waitFor(
      (m) => m.type == SignalType.helloChallenge || m.type == SignalType.error,
    );
    if (challenge.type == SignalType.error) return challenge;
    final proof = handshakeMac(
      key: credentialKey(mode, proofCredential ?? credential),
      label: kClientProofLabel,
      clientNonce: clientNonce,
      hostNonce: challenge.payload['sn']! as String,
      clientId: senderId,
      hostId: challenge.senderId,
      sessionId: challenge.sessionId,
    );
    send(SignalType.helloProof, <String, Object?>{
      'mac': proof,
    }, session: challenge.sessionId);
    return waitFor(
      (m) => m.type == SignalType.helloAck || m.type == SignalType.error,
    );
  }

  Future<void> close() async {
    try {
      await socket.close();
    } catch (_) {}
  }
}

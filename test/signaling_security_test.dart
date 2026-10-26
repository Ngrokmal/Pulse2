// Security behaviour of the real signaling service over loopback sockets.
// These tests show the handshake, filters and limits behave as designed.
// They are NOT a security audit and say nothing about a real hotspot.
// ignore_for_file: avoid_relative_lib_imports
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/features/video_call/models/handshake_auth.dart';
import '../lib/features/video_call/models/session_tokens.dart';
import '../lib/features/video_call/models/signal_message.dart';
import '../lib/features/video_call/services/local_signal_service.dart';
import '../lib/features/video_call/services/network_discovery_service.dart';
import 'support/raw_client.dart';

class _NoDiscovery extends NetworkDiscoveryService {
  const _NoDiscovery();

  @override
  Future<AddressDiscoveryResult> listLocalAddresses() async {
    return const AddressDiscoveryResult(addresses: <LocalAddress>[]);
  }
}

Future<void> _waitFor(
  bool Function() condition, {
  String reason = 'condition',
  Duration timeout = const Duration(seconds: 8),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for $reason');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

LocalSignalService _service({
  Duration handshakeTimeout = const Duration(seconds: 3),
}) {
  final service = LocalSignalService(
    discovery: const _NoDiscovery(),
    connectTimeout: const Duration(seconds: 3),
    handshakeTimeout: handshakeTimeout,
    appPingInterval: const Duration(seconds: 30),
  );
  addTearDown(() async {
    await service.stop();
    service.dispose();
  });
  return service;
}

Future<LocalSignalService> _host({
  Duration handshakeTimeout = const Duration(seconds: 3),
}) async {
  final host = _service(handshakeTimeout: handshakeTimeout);
  await host.startHost(port: 0);
  expect(host.phase, SignalPhase.listening);
  return host;
}

/// A fake host that does NOT know the credential. [onMessage] decides what
/// it answers. Every frame it receives is kept in [frames].
Future<HttpServer> _impostor(
  List<String> frames,
  void Function(WebSocket socket, SignalMessage message) onMessage,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen((request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    socket.listen((Object? data) {
      frames.add(data! as String);
      onMessage(socket, SignalMessage.decode(data));
    });
  });
  return server;
}

void main() {
  group('credentials', () {
    test('host creates a fresh code and secret for every start', () async {
      final codes = <String>{};
      final secrets = <String>{};
      final host = _service();
      for (var i = 0; i < 4; i++) {
        await host.startHost(port: 0);
        codes.add(host.pairingCode!);
        secrets.add(host.sessionSecret!);
        expect(isValidSessionSecret(host.sessionSecret), isTrue);
        await host.stop();
        expect(host.pairingCode, isNull);
        expect(host.sessionSecret, isNull);
      }
      expect(secrets, hasLength(4));
      expect(codes.length, greaterThan(1));
    });

    test('a client never exposes the host secret', () async {
      final host = await _host();
      final client = _service();
      await client.join(
        host: '127.0.0.1',
        port: host.listeningPort!,
        sessionSecret: host.sessionSecret,
      );
      await _waitFor(() => client.isConnected, reason: 'QR-style join');
      expect(client.sessionSecret, isNull);
    });
  });

  group('joining', () {
    test('joining with the QR secret works', () async {
      final host = await _host();
      final client = _service();
      await client.join(
        host: '127.0.0.1',
        port: host.listeningPort!,
        sessionSecret: host.sessionSecret,
      );
      await _waitFor(
        () => host.isConnected && client.isConnected,
        reason: 'both sides connected',
      );
      expect(client.sessionId, host.sessionId);
    });

    test(
      'a wrong QR secret is rejected and the host keeps listening',
      () async {
        final host = await _host();
        final client = _service();
        await client.join(
          host: '127.0.0.1',
          port: host.listeningPort!,
          sessionSecret: generateSessionSecret(),
        );
        await _waitFor(
          () => client.phase == SignalPhase.error,
          reason: 'client error',
        );
        expect(client.isConnected, isFalse);
        expect(client.statusText, contains('Wrong pairing code or QR code'));
        await _waitFor(
          () => host.phase == SignalPhase.listening,
          reason: 'host listening',
        );
        expect(host.isConnected, isFalse);
      },
    );

    test(
      'a malformed QR secret is refused before any socket is opened',
      () async {
        final client = _service();
        await client.join(
          host: '127.0.0.1',
          port: 8080,
          sessionSecret: 'not-a-secret',
        );
        expect(client.phase, SignalPhase.error);
        expect(client.canRetry, isFalse);
      },
    );

    test('failed QR attempts count towards the lockout', () async {
      final host = await _host();
      for (var i = 0; i < 5; i++) {
        final client = _service();
        await client.join(
          host: '127.0.0.1',
          port: host.listeningPort!,
          sessionSecret: generateSessionSecret(),
        );
        await _waitFor(
          () => client.phase == SignalPhase.error,
          reason: 'attempt ${i + 1}',
        );
      }
      await _waitFor(
        () => host.phase == SignalPhase.error,
        reason: 'host lockout',
      );
      expect(host.statusText, contains('Too many'));
      expect(host.sessionSecret, isNull);
      expect(host.pairingCode, isNull);
    });

    test(
      'a second join call while connecting opens only one connection',
      () async {
        final host = await _host();
        final client = _service();
        final first = client.join(
          host: '127.0.0.1',
          port: host.listeningPort!,
          pairingCode: host.pairingCode!,
        );
        final second = client.join(
          host: '127.0.0.1',
          port: host.listeningPort!,
          pairingCode: host.pairingCode!,
        );
        await Future.wait(<Future<void>>[first, second]);
        await _waitFor(() => client.isConnected, reason: 'connected');
        expect(
          host.log.where((e) => e.text.contains('busy')),
          isEmpty,
          reason: 'the host saw exactly one phone',
        );
        // Joining again while connected is ignored, not a second socket.
        await client.join(
          host: '127.0.0.1',
          port: host.listeningPort!,
          pairingCode: host.pairingCode!,
        );
        expect(client.isConnected, isTrue);
        expect(host.log.where((e) => e.text.contains('busy')), isEmpty);
      },
    );
  });

  group('handshake attacks', () {
    test('code mode with the right code works', () async {
      final host = await _host();
      final good = await RawClient.connect(host.listeningPort!);
      addTearDown(good.close);
      final ack = await good.handshake(CredentialMode.code, host.pairingCode!);
      expect(ack.type, SignalType.helloAck);
      expect(isValidMac(ack.payload['mac']), isTrue);
    });

    test('a proof made with another credential is refused', () async {
      final host = await _host();
      final raw = await RawClient.connect(host.listeningPort!);
      addTearDown(raw.close);
      final reply = await raw.handshake(
        CredentialMode.secret,
        host.sessionSecret!,
        proofCredential: generateSessionSecret(),
      );
      expect(reply.type, SignalType.error);
      expect(reply.payload['code'], SignalErrorCode.badPairingCode);
      expect(host.isConnected, isFalse);
    });

    test('a code cannot be used as the secret', () async {
      final host = await _host();
      final raw = await RawClient.connect(host.listeningPort!);
      addTearDown(raw.close);
      final reply = await raw.handshake(
        CredentialMode.secret,
        host.pairingCode!,
      );
      expect(reply.payload['code'], SignalErrorCode.badPairingCode);
    });

    test('a proof recorded for another challenge cannot be replayed', () async {
      final host = await _host();
      final raw = await RawClient.connect(host.listeningPort!);
      addTearDown(raw.close);
      final clientNonce = generateNonce();
      raw.send(SignalType.hello, <String, Object?>{
        'mode': 'code',
        'cn': clientNonce,
      });
      final challenge = await raw.waitForType(SignalType.helloChallenge);
      // Correct credential, but computed over an OLD host nonce.
      final stale = handshakeMac(
        key: credentialKey(CredentialMode.code, host.pairingCode!),
        label: kClientProofLabel,
        clientNonce: clientNonce,
        hostNonce: generateNonce(),
        clientId: raw.senderId,
        hostId: challenge.senderId,
        sessionId: challenge.sessionId,
      );
      raw.send(SignalType.helloProof, <String, Object?>{
        'mac': stale,
      }, session: challenge.sessionId);
      final reply = await raw.waitFor((m) => m.type == SignalType.error);
      expect(reply.payload['code'], SignalErrorCode.badPairingCode);
    });

    test('the old clear-text pairingCode hello is not accepted', () async {
      final host = await _host();
      final raw = await RawClient.connect(host.listeningPort!);
      addTearDown(raw.close);
      raw.send(SignalType.hello, <String, Object?>{
        'pairingCode': host.pairingCode,
      });
      final reply = await raw.waitFor((m) => m.type == SignalType.error);
      expect(reply.payload['code'], SignalErrorCode.malformed);
      expect(host.isConnected, isFalse);
    });

    test('bad mode or nonce is refused as malformed', () async {
      final host = await _host();
      for (final payload in <Map<String, Object?>>[
        {'mode': 'bogus', 'cn': generateNonce()},
        {'mode': 'code', 'cn': 'short'},
        {'mode': 'code'},
        {'cn': generateNonce()},
      ]) {
        final raw = await RawClient.connect(host.listeningPort!);
        addTearDown(raw.close);
        raw.send(SignalType.hello, payload);
        final reply = await raw.waitFor((m) => m.type == SignalType.error);
        expect(reply.payload['code'], SignalErrorCode.malformed);
        await _waitFor(
          () => host.phase == SignalPhase.listening,
          reason: 'host to release the bad peer',
        );
      }
    });

    test('call messages before the handshake finishes are refused', () async {
      final host = await _host();
      final delivered = <SignalMessage>[];
      final sub = host.callMessages.listen(delivered.add);
      addTearDown(sub.cancel);
      final raw = await RawClient.connect(host.listeningPort!);
      addTearDown(raw.close);
      raw.send(SignalType.offer, <String, Object?>{
        'type': 'offer',
        'sdp': 'v=0\r\n',
      });
      final reply = await raw.waitFor((m) => m.type == SignalType.error);
      expect(reply.payload['code'], SignalErrorCode.unexpectedMessage);
      expect(delivered, isEmpty);
      expect(host.isConnected, isFalse);
    });

    test('a proof from a different sender id is refused', () async {
      final host = await _host();
      final raw = await RawClient.connect(host.listeningPort!);
      addTearDown(raw.close);
      raw.send(SignalType.hello, <String, Object?>{
        'mode': 'code',
        'cn': generateNonce(),
      });
      final challenge = await raw.waitForType(SignalType.helloChallenge);
      final other = await RawClient.connect(
        host.listeningPort!,
        senderId: 'someone-else',
      );
      addTearDown(other.close);
      // The second socket is refused outright: the slot is taken.
      final busy = await other.waitFor((m) => m.type == SignalType.error);
      expect(busy.payload['code'], SignalErrorCode.hostBusy);
      // And the first socket cannot switch identity mid-handshake.
      raw.socket.add(
        SignalMessage(
          type: SignalType.helloProof,
          sessionId: challenge.sessionId,
          senderId: 'changed-identity',
          payload: <String, Object?>{'mac': 'a' * 64},
        ).encode(),
      );
      final reply = await raw.waitFor((m) => m.type == SignalType.error);
      expect(reply.payload['code'], SignalErrorCode.unexpectedMessage);
    });

    test('an unfinished handshake times out and frees the slot', () async {
      final host = await _host(
        handshakeTimeout: const Duration(milliseconds: 300),
      );
      final idle = await RawClient.connect(host.listeningPort!);
      addTearDown(idle.close);
      await _waitFor(() => idle.closed, reason: 'host to close the idle peer');
      final client = _service();
      await client.join(
        host: '127.0.0.1',
        port: host.listeningPort!,
        pairingCode: host.pairingCode!,
      );
      await _waitFor(() => client.isConnected, reason: 'a normal join');
    });

    test('a second peer is refused even during the first handshake', () async {
      final host = await _host();
      final first = await RawClient.connect(host.listeningPort!);
      addTearDown(first.close);
      first.send(SignalType.hello, <String, Object?>{
        'mode': 'code',
        'cn': generateNonce(),
      });
      await first.waitForType(SignalType.helloChallenge);
      final second = await RawClient.connect(host.listeningPort!);
      addTearDown(second.close);
      final reply = await second.waitFor((m) => m.type == SignalType.error);
      expect(reply.payload['code'], SignalErrorCode.hostBusy);
    });
  });

  group('request filters', () {
    test('a browser-style request with an Origin header is refused', () async {
      final host = await _host();
      await expectLater(
        RawClient.connect(
          host.listeningPort!,
          headers: <String, dynamic>{'origin': 'http://evil.example'},
        ),
        throwsA(isA<WebSocketException>()),
      );
      expect(host.isConnected, isFalse);
      expect(host.phase, SignalPhase.listening);
    });
  });

  group('impostor host', () {
    test(
      'a host that cannot prove the secret is refused, secret not sent',
      () async {
        final frames = <String>[];
        final server = await _impostor(frames, (socket, message) {
          if (message.type == SignalType.hello) {
            socket.add(
              SignalMessage(
                type: SignalType.helloChallenge,
                sessionId: 'fake-session',
                senderId: 'impostor',
                payload: <String, Object?>{'sn': generateNonce()},
              ).encode(),
            );
          } else if (message.type == SignalType.helloProof) {
            socket.add(
              SignalMessage(
                type: SignalType.helloAck,
                sessionId: 'fake-session',
                senderId: 'impostor',
                payload: <String, Object?>{'accepted': true, 'mac': 'a' * 64},
              ).encode(),
            );
          }
        });
        final secret = generateSessionSecret();
        final client = _service();
        await client.join(
          host: '127.0.0.1',
          port: server.port,
          sessionSecret: secret,
        );
        await _waitFor(
          () => client.phase == SignalPhase.error,
          reason: 'client to refuse the impostor',
        );
        expect(client.isConnected, isFalse);
        expect(client.statusText, contains('could not prove'));
        expect(frames, isNotEmpty);
        expect(frames.any((f) => f.contains(secret)), isFalse);
      },
    );

    test('a typed code is not sent over the wire either', () async {
      final frames = <String>[];
      final server = await _impostor(frames, (socket, message) {
        if (message.type == SignalType.hello) {
          socket.add(
            SignalMessage(
              type: SignalType.helloChallenge,
              sessionId: 'fake-session',
              senderId: 'impostor',
              payload: <String, Object?>{'sn': generateNonce()},
            ).encode(),
          );
        }
      });
      final client = _service();
      await client.join(
        host: '127.0.0.1',
        port: server.port,
        pairingCode: '482913',
      );
      await _waitFor(() => frames.length >= 2, reason: 'hello and proof');
      expect(frames.any((f) => f.contains('482913')), isFalse);
      await client.stop();
    });

    test('an acknowledgement without a challenge is refused', () async {
      final frames = <String>[];
      final server = await _impostor(frames, (socket, message) {
        if (message.type == SignalType.hello) {
          socket.add(
            SignalMessage(
              type: SignalType.helloAck,
              sessionId: 'fake-session',
              senderId: 'impostor',
              payload: const <String, Object?>{'accepted': true},
            ).encode(),
          );
        }
      });
      final client = _service();
      await client.join(
        host: '127.0.0.1',
        port: server.port,
        pairingCode: '123456',
      );
      await _waitFor(
        () => client.phase == SignalPhase.error,
        reason: 'client to refuse an unexpected ack',
      );
      expect(client.isConnected, isFalse);
    });
  });

  group('cleanup', () {
    test('a disconnecting phone frees the host for the next one', () async {
      final host = await _host();
      final first = _service();
      await first.join(
        host: '127.0.0.1',
        port: host.listeningPort!,
        pairingCode: host.pairingCode!,
      );
      await _waitFor(() => host.isConnected, reason: 'first phone');
      await first.stop();
      await _waitFor(
        () => host.phase == SignalPhase.listening,
        reason: 'host to release the first phone',
      );
      expect(host.peerAddress, isNull);

      final second = _service();
      await second.join(
        host: '127.0.0.1',
        port: host.listeningPort!,
        pairingCode: host.pairingCode!,
      );
      await _waitFor(() => second.isConnected, reason: 'second phone');
    });

    test(
      'stopping the host closes the port and wipes the credentials',
      () async {
        final host = await _host();
        final port = host.listeningPort!;
        await host.stop();
        expect(host.sessionSecret, isNull);
        expect(host.pairingCode, isNull);
        await expectLater(
          WebSocket.connect(
            'ws://127.0.0.1:$port/signal',
          ).timeout(const Duration(seconds: 3)),
          throwsA(anything),
        );
      },
    );

    test('repeated stop and dispose are harmless', () async {
      final host = await _host();
      await host.stop();
      await host.stop();
      final other = LocalSignalService(discovery: const _NoDiscovery());
      other.dispose();
      other.dispose();
      await other.stop();
    });

    test(
      'a protocol error never leaves the service marked connected',
      () async {
        final host = await _host();
        final raw = await RawClient.connect(host.listeningPort!);
        addTearDown(raw.close);
        raw.socket.add('{"v":$kSignalProtocolVersion,"type":"chat"');
        await raw.waitFor((m) => m.type == SignalType.error);
        expect(host.isConnected, isFalse);
      },
    );
  });
}

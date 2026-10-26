// Loopback tests: host and client run in the same process on 127.0.0.1.
// They prove the protocol logic works, NOT that a real Android hotspot
// between two phones works.
// ignore_for_file: avoid_relative_lib_imports
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/features/video_call/models/signal_message.dart';
import '../lib/features/video_call/services/local_signal_service.dart';
import '../lib/features/video_call/services/network_discovery_service.dart';

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

LocalSignalService _service() {
  final service = LocalSignalService(
    discovery: const _NoDiscovery(),
    connectTimeout: const Duration(seconds: 3),
    handshakeTimeout: const Duration(seconds: 3),
    appPingInterval: const Duration(milliseconds: 200),
  );
  addTearDown(() async {
    await service.stop();
    service.dispose();
  });
  return service;
}

Future<LocalSignalService> _startedHost() async {
  final host = _service();
  await host.startHost(port: 0);
  expect(host.phase, SignalPhase.listening);
  expect(host.listeningPort, isNotNull);
  return host;
}

Future<LocalSignalService> _connectedClient(LocalSignalService host) async {
  final client = _service();
  await client.join(
    host: '127.0.0.1',
    port: host.listeningPort!,
    pairingCode: host.pairingCode!,
  );
  await _waitFor(
    () => host.isConnected && client.isConnected,
    reason: 'host and client to connect',
  );
  return client;
}

String _wrongCode(String realCode) =>
    realCode == '111111' ? '222222' : '111111';

Future<SignalMessage> _firstReply(WebSocket socket) async {
  final raw = await socket.first.timeout(const Duration(seconds: 5));
  return SignalMessage.decode(raw);
}

void main() {
  test('host and client connect and exchange messages both ways', () async {
    final host = await _startedHost();
    final client = await _connectedClient(host);

    expect(host.sessionId, isNotNull);
    expect(client.sessionId, host.sessionId);

    client.sendChat('hello from client');
    host.sendChat('hello from host');
    await _waitFor(
      () => host.log.any(
        (e) => e.kind == LogKind.received && e.text == 'hello from client',
      ),
      reason: 'host to receive the client message',
    );
    await _waitFor(
      () => client.log.any(
        (e) => e.kind == LogKind.received && e.text == 'hello from host',
      ),
      reason: 'client to receive the host message',
    );

    client.sendPing();
    await _waitFor(() => client.lastRttMs != null, reason: 'a pong');
    expect(client.lastRttMs, greaterThanOrEqualTo(0));
  });

  test('wrong pairing code is rejected and host keeps listening', () async {
    final host = await _startedHost();
    final client = _service();
    await client.join(
      host: '127.0.0.1',
      port: host.listeningPort!,
      pairingCode: _wrongCode(host.pairingCode!),
    );
    await _waitFor(
      () => client.phase == SignalPhase.error,
      reason: 'client error',
    );
    expect(client.statusText, contains('Wrong pairing code'));
    expect(client.canRetry, isTrue);
    await _waitFor(
      () => host.phase == SignalPhase.listening,
      reason: 'host to keep listening',
    );
    expect(host.isConnected, isFalse);
  });

  test('five wrong codes stop the host', () async {
    final host = await _startedHost();
    final wrong = _wrongCode(host.pairingCode!);
    for (var i = 0; i < 5; i++) {
      final client = _service();
      await client.join(
        host: '127.0.0.1',
        port: host.listeningPort!,
        pairingCode: wrong,
      );
      await _waitFor(
        () => client.phase == SignalPhase.error,
        reason: 'client error in attempt ${i + 1}',
      );
    }
    await _waitFor(
      () => host.phase == SignalPhase.error,
      reason: 'host lockout',
    );
    expect(host.statusText, contains('Too many'));
  });

  test('second client is rejected while one phone is connected', () async {
    final host = await _startedHost();
    final client = await _connectedClient(host);

    final extra = await WebSocket.connect(
      'ws://127.0.0.1:${host.listeningPort}${LocalSignalService.signalPath}',
    );
    addTearDown(() => extra.close());
    final reply = await _firstReply(extra);
    expect(reply.type, SignalType.error);
    expect(reply.payload['code'], SignalErrorCode.hostBusy);
    expect(client.isConnected, isTrue);
    expect(host.isConnected, isTrue);
  });

  test('protocol version mismatch is reported', () async {
    final host = await _startedHost();
    final raw = await WebSocket.connect(
      'ws://127.0.0.1:${host.listeningPort}${LocalSignalService.signalPath}',
    );
    addTearDown(() => raw.close());
    raw.add(
      jsonEncode(<String, Object?>{
        'v': kSignalProtocolVersion + 1,
        'type': 'hello',
        'session': '',
        'sender': 'raw-client',
        'payload': <String, Object?>{'pairingCode': host.pairingCode},
      }),
    );
    final reply = await _firstReply(raw);
    expect(reply.type, SignalType.error);
    expect(reply.payload['code'], SignalErrorCode.protocolMismatch);
    await _waitFor(
      () => host.phase == SignalPhase.listening && !host.isConnected,
      reason: 'host to drop the peer',
    );
  });

  test('malformed and oversized handshake data is rejected', () async {
    final host = await _startedHost();
    final url =
        'ws://127.0.0.1:${host.listeningPort}${LocalSignalService.signalPath}';

    final malformed = await WebSocket.connect(url);
    addTearDown(() => malformed.close());
    malformed.add('this is not json');
    final first = await _firstReply(malformed);
    expect(first.payload['code'], SignalErrorCode.malformed);
    await _waitFor(
      () => host.phase == SignalPhase.listening,
      reason: 'host to drop the malformed peer',
    );

    final huge = await WebSocket.connect(url);
    addTearDown(() => huge.close());
    huge.add('x' * (kMaxSignalMessageChars + 1));
    final second = await _firstReply(huge);
    expect(second.payload['code'], SignalErrorCode.tooLarge);
  });

  test('wrong path is not upgraded to a WebSocket', () async {
    final host = await _startedHost();
    await expectLater(
      WebSocket.connect('ws://127.0.0.1:${host.listeningPort}/other'),
      throwsA(isA<WebSocketException>()),
    );
  });

  test('host stop is reported to the client, which can retry', () async {
    final host = await _startedHost();
    final client = await _connectedClient(host);
    await host.stop();
    await _waitFor(
      () => client.phase == SignalPhase.disconnected,
      reason: 'client to notice the host stopped',
    );
    expect(client.canRetry, isTrue);
    expect(host.phase, SignalPhase.idle);
  });

  test('connection refused gives a clear message', () async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closedPort = probe.port;
    await probe.close();

    final client = _service();
    await client.join(
      host: '127.0.0.1',
      port: closedPort,
      pairingCode: '123456',
    );
    await _waitFor(
      () => client.phase == SignalPhase.error,
      reason: 'a connection error',
    );
    expect(client.statusText.toLowerCase(), contains('refused'));
  });

  test('invalid input is reported without opening a socket', () async {
    final client = _service();
    await client.join(host: '999.1.1.1', port: 8080, pairingCode: '123456');
    expect(client.phase, SignalPhase.error);
    await client.join(host: '127.0.0.1', port: 8080, pairingCode: '12');
    expect(client.phase, SignalPhase.error);
    expect(client.canRetry, isFalse);
  });

  test('port already in use is reported', () async {
    final first = await _startedHost();
    final second = _service();
    await second.startHost(port: first.listeningPort!);
    expect(second.phase, SignalPhase.error);
    expect(second.statusText, contains('already in use'));
  });
}

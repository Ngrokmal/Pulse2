// LOOPBACK tests: host and client run in this process on 127.0.0.1 and use
// the real WebSocket signaling service, but the peer connections are FAKES.
// They show that call messages are routed, authenticated and ordered
// correctly. They do NOT prove that a real hotspot, the camera, audio or
// native WebRTC media works. That needs two phones.
// ignore_for_file: avoid_relative_lib_imports
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../lib/features/video_call/models/call_signal.dart';
import '../lib/features/video_call/models/call_state.dart';
import '../lib/features/video_call/models/handshake_auth.dart';
import '../lib/features/video_call/models/signal_message.dart';
import '../lib/features/video_call/services/call_negotiator.dart';
import '../lib/features/video_call/services/local_signal_service.dart';
import '../lib/features/video_call/services/network_discovery_service.dart';
import 'support/raw_client.dart';

const String _fakeSdp = 'v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n';

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
    appPingInterval: const Duration(seconds: 30),
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

class _FakeLink implements PeerLink {
  final List<String> calls = <String>[];

  @override
  void Function(IceCandidatePayload candidate)? onLocalCandidate;
  @override
  void Function(LinkConnectionState state)? onConnectionState;
  @override
  void Function()? onRemoteTrack;
  @override
  void Function(MediaSnapshot snapshot)? onMediaSnapshot;

  @override
  Future<void> open() async => calls.add('open');

  @override
  Future<String> createOffer() async {
    calls.add('createOffer');
    onLocalCandidate?.call(
      const IceCandidatePayload(
        candidate: 'candidate:1 1 udp 2122260223 192.0.2.1 40001 typ host',
        sdpMid: '0',
        sdpMLineIndex: 0,
      ),
    );
    return _fakeSdp;
  }

  @override
  Future<void> acceptOffer(String sdp) async => calls.add('acceptOffer');

  @override
  Future<String> createAnswer() async {
    calls.add('createAnswer');
    return _fakeSdp;
  }

  @override
  Future<void> acceptAnswer(String sdp) async => calls.add('acceptAnswer');

  @override
  Future<void> addRemoteCandidate(IceCandidatePayload candidate) async {
    calls.add('addCandidate');
  }

  @override
  Future<void> close() async => calls.add('close');
}

CallNegotiator _negotiatorFor(
  LocalSignalService signal,
  NegotiationRole role,
  _FakeLink link,
) {
  final negotiator = CallNegotiator(
    role: role,
    linkFactory: () => link,
    send: signal.sendCall,
  );
  final sub = signal.callMessages.listen(
    (message) => unawaited(negotiator.onSignal(message)),
  );
  addTearDown(() async {
    await sub.cancel();
    negotiator.dispose();
  });
  return negotiator;
}

void main() {
  test('negotiation runs over the real signaling channel', () async {
    final host = await _startedHost();
    final client = await _connectedClient(host);
    final hostLink = _FakeLink();
    final clientLink = _FakeLink();
    final hostCall = _negotiatorFor(host, NegotiationRole.offerer, hostLink);
    final clientCall = _negotiatorFor(
      client,
      NegotiationRole.answerer,
      clientLink,
    );

    await hostCall.startCall();
    await clientCall.startCall();
    await _waitFor(
      () => hostCall.milestones.negotiated && clientCall.milestones.negotiated,
      reason: 'offer and answer to be exchanged',
    );
    expect(hostLink.calls, containsAllInOrder(['open', 'createOffer']));
    expect(hostLink.calls, contains('acceptAnswer'));
    expect(
      clientLink.calls,
      containsAllInOrder(['open', 'acceptOffer', 'createAnswer']),
    );
    await _waitFor(
      () => clientLink.calls.contains('addCandidate'),
      reason: 'the host candidate to arrive',
    );

    hostLink.onConnectionState?.call(LinkConnectionState.connected);
    clientLink.onConnectionState?.call(LinkConnectionState.connected);
    expect(hostCall.phase, CallPhase.connected);
    expect(clientCall.phase, CallPhase.connected);

    // Ending the call must leave the signaling connection (and Host) alone.
    await hostCall.hangUp();
    await _waitFor(
      () => clientCall.phase == CallPhase.ended,
      reason: 'the other phone to see the end',
    );
    expect(host.isConnected, isTrue);
    expect(client.isConnected, isTrue);
    expect(host.isHostRunning, isTrue);
  });

  test(
    'sendCall only carries call messages over a connected channel',
    () async {
      final host = await _startedHost();
      expect(
        host.sendCall(SignalType.callReady, callReadyPayload()),
        CallSendResult.notConnected,
      );

      final client = await _connectedClient(host);
      expect(
        client.sendCall(SignalType.chat, <String, Object?>{'text': 'hi'}),
        CallSendResult.notACallMessage,
      );
      expect(
        client.sendCall(
          SignalType.offer,
          SdpPayload.offer('v=0${'a' * kMaxSignalMessageChars}').toPayload(),
        ),
        CallSendResult.tooLarge,
      );

      final received = <SignalMessage>[];
      final sub = host.callMessages.listen(received.add);
      addTearDown(sub.cancel);
      expect(
        client.sendCall(SignalType.callReady, callReadyPayload()),
        CallSendResult.sent,
      );
      await _waitFor(() => received.isNotEmpty, reason: 'call_ready');
      expect(received.single.type, SignalType.callReady);
    },
  );

  test(
    'call messages from another session or sender are not delivered',
    () async {
      final host = await _startedHost();
      final delivered = <SignalMessage>[];
      final sub = host.callMessages.listen(delivered.add);
      addTearDown(sub.cancel);

      final raw = await RawClient.connect(host.listeningPort!);
      addTearDown(raw.close);
      final ack = await raw.handshake(CredentialMode.code, host.pairingCode!);
      expect(ack.type, SignalType.helloAck);
      final session = ack.sessionId;

      String offer({required String sessionId, required String sender}) {
        return jsonEncode(<String, Object?>{
          'v': kSignalProtocolVersion,
          'type': 'offer',
          'session': sessionId,
          'sender': sender,
          'payload': SdpPayload.offer(_fakeSdp).toPayload(),
        });
      }

      raw.socket.add(
        offer(sessionId: 'someone-elses-session', sender: 'raw-client'),
      );
      raw.socket.add(offer(sessionId: session, sender: 'impostor'));
      await _waitFor(
        () =>
            raw.received
                .where(
                  (m) =>
                      m.type == SignalType.error &&
                      m.payload['code'] == SignalErrorCode.sessionMismatch,
                )
                .length >=
            2,
        reason: 'two session_mismatch errors',
      );
      expect(delivered, isEmpty);

      raw.socket.add(offer(sessionId: session, sender: 'raw-client'));
      await _waitFor(() => delivered.isNotEmpty, reason: 'the valid offer');
      expect(delivered.single.type, SignalType.offer);
      expect(SdpPayload.fromMessage(delivered.single).sdp, _fakeSdp);
    },
  );

  test('malformed call messages are refused and never delivered', () async {
    final host = await _startedHost();
    final delivered = <SignalMessage>[];
    final sub = host.callMessages.listen(delivered.add);
    addTearDown(sub.cancel);

    final raw = await RawClient.connect(host.listeningPort!);
    addTearDown(raw.close);
    final ack = await raw.handshake(CredentialMode.code, host.pairingCode!);
    expect(ack.type, SignalType.helloAck);

    // Envelope fields missing: refused by the envelope validation.
    raw.socket.add('{"v":$kSignalProtocolVersion,"type":"offer"}');
    await _waitFor(
      () => raw.received.any(
        (m) =>
            m.type == SignalType.error &&
            m.payload['code'] == SignalErrorCode.malformed,
      ),
      reason: 'a malformed_message error',
    );
    expect(delivered, isEmpty);
    // A bad message after the handshake does not drop the connection.
    expect(host.isConnected, isTrue);
  });
}

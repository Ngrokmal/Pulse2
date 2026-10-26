// Negotiation logic tests with a FAKE peer link and an in-memory message
// channel. They check ordering, roles, candidate handling and state changes.
// They do NOT test native WebRTC, the camera, audio or any real network.
// ignore_for_file: avoid_relative_lib_imports
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import '../lib/features/video_call/models/call_signal.dart';
import '../lib/features/video_call/models/call_state.dart';
import '../lib/features/video_call/models/signal_message.dart';
import '../lib/features/video_call/services/call_negotiator.dart';

const String _fakeSdp = 'v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n';

IceCandidatePayload _candidate(int n) => IceCandidatePayload(
  candidate: 'candidate:$n 1 udp 2122260223 192.0.2.$n 4000$n typ host',
  sdpMid: '0',
  sdpMLineIndex: 0,
);

class FakeLink implements PeerLink {
  FakeLink({this.candidatesPerSdp = 2, this.failOpen = false});

  final int candidatesPerSdp;
  final bool failOpen;
  final List<String> calls = <String>[];
  bool closed = false;

  @override
  void Function(IceCandidatePayload candidate)? onLocalCandidate;
  @override
  void Function(LinkConnectionState state)? onConnectionState;
  @override
  void Function()? onRemoteTrack;
  @override
  void Function(MediaSnapshot snapshot)? onMediaSnapshot;

  void _gather() {
    for (var i = 1; i <= candidatesPerSdp; i++) {
      onLocalCandidate?.call(_candidate(i));
    }
  }

  @override
  Future<void> open() async {
    calls.add('open');
    if (failOpen) throw StateError('no camera');
  }

  @override
  Future<String> createOffer() async {
    calls.add('createOffer');
    // Real WebRTC gathers candidates while setLocalDescription runs, which is
    // before the offer message can be sent.
    _gather();
    return _fakeSdp;
  }

  @override
  Future<void> acceptOffer(String sdp) async => calls.add('acceptOffer');

  @override
  Future<String> createAnswer() async {
    calls.add('createAnswer');
    _gather();
    return _fakeSdp;
  }

  @override
  Future<void> acceptAnswer(String sdp) async => calls.add('acceptAnswer');

  @override
  Future<void> addRemoteCandidate(IceCandidatePayload candidate) async {
    calls.add('addCandidate');
  }

  @override
  Future<void> close() async {
    calls.add('close');
    closed = true;
  }
}

/// Two phones connected by an in-memory, ordered channel.
class Pair {
  Pair({
    Duration connectTimeout = const Duration(seconds: 30),
    Duration disconnectGrace = const Duration(seconds: 8),
  }) {
    a = CallNegotiator(
      role: NegotiationRole.offerer,
      linkFactory: () => linkA = FakeLink(),
      send: (type, payload) => _deliver('A', b, type, payload),
      connectTimeout: connectTimeout,
      disconnectGrace: disconnectGrace,
    );
    b = CallNegotiator(
      role: NegotiationRole.answerer,
      linkFactory: () => linkB = FakeLink(),
      send: (type, payload) => _deliver('B', a, type, payload),
      connectTimeout: connectTimeout,
      disconnectGrace: disconnectGrace,
    );
  }

  late final CallNegotiator a;
  late final CallNegotiator b;
  late FakeLink linkA;
  late FakeLink linkB;

  /// Every message in send order, e.g. `A:offer`.
  final List<String> wire = <String>[];
  bool blockToB = false;

  CallSendResult _deliver(
    String from,
    CallNegotiator to,
    SignalType type,
    Map<String, Object?> payload,
  ) {
    wire.add('$from:${type.wireName}');
    if (from == 'A' && blockToB) return CallSendResult.sent;
    final message = SignalMessage(
      type: type,
      sessionId: 'session',
      senderId: from,
      payload: payload,
    );
    scheduleMicrotask(() => unawaited(to.onSignal(message)));
    return CallSendResult.sent;
  }

  void dispose() {
    a.dispose();
    b.dispose();
  }
}

SignalMessage _msg(SignalType type, Map<String, Object?> payload) =>
    SignalMessage(
      type: type,
      sessionId: 'session',
      senderId: 'peer',
      payload: payload,
    );

Future<Pair> _connectedPair({Pair? using}) async {
  final pair = using ?? Pair();
  addTearDown(pair.dispose);
  await pair.a.startCall();
  await pair.b.startCall();
  await pumpEventQueue();
  pair.linkA.onConnectionState?.call(LinkConnectionState.checking);
  pair.linkB.onConnectionState?.call(LinkConnectionState.checking);
  pair.linkA.onConnectionState?.call(LinkConnectionState.connected);
  pair.linkB.onConnectionState?.call(LinkConnectionState.connected);
  return pair;
}

void main() {
  test('full negotiation: one offer, one answer, ICE, then media', () async {
    final pair = await _connectedPair();

    expect(
      pair.wire.where((e) => e.endsWith(':offer')),
      <String>['A:offer'],
      reason: 'exactly one offer, from the offerer',
    );
    expect(pair.wire.where((e) => e.endsWith(':answer')), <String>['B:answer']);
    expect(pair.linkA.calls, containsAllInOrder(['open', 'createOffer']));
    expect(pair.linkA.calls, contains('acceptAnswer'));
    expect(
      pair.linkB.calls,
      containsAllInOrder(['open', 'acceptOffer', 'createAnswer']),
    );
    expect(pair.linkB.calls, isNot(contains('createOffer')));

    expect(pair.a.phase, CallPhase.connected);
    expect(pair.b.phase, CallPhase.connected);
    expect(pair.a.milestones.negotiated, isTrue);
    expect(pair.a.milestones.iceConnected, isTrue);
    // Connected is not "media flowing": no frames were reported yet.
    expect(pair.a.milestones.remoteVideoFrames, isFalse);
    expect(pair.a.phase, isNot(CallPhase.mediaFlowing));

    pair.linkA.onRemoteTrack?.call();
    expect(pair.a.milestones.remoteTrack, isTrue);
    expect(pair.a.phase, CallPhase.connected);

    pair.linkA.onMediaSnapshot?.call(
      const MediaSnapshot(receivedVideoFrames: 30, receivedAudioBytes: 900),
    );
    expect(pair.a.phase, CallPhase.mediaFlowing);
    expect(pair.a.milestones.remoteVideoFrames, isTrue);
    expect(pair.a.milestones.remoteAudioFlowing, isTrue);
  });

  test('local candidates are sent after the SDP they belong to', () async {
    final pair = await _connectedPair();
    final offerAt = pair.wire.indexOf('A:offer');
    final firstCandidateA = pair.wire.indexOf('A:candidate');
    expect(offerAt, greaterThanOrEqualTo(0));
    expect(firstCandidateA, greaterThan(offerAt));

    final answerAt = pair.wire.indexOf('B:answer');
    final firstCandidateB = pair.wire.indexOf('B:candidate');
    expect(firstCandidateB, greaterThan(answerAt));
    expect(pair.wire.where((e) => e == 'A:candidate'), hasLength(2));
    expect(pair.wire.where((e) => e == 'B:candidate'), hasLength(2));
    // Each side applied the other side's candidates.
    expect(pair.linkA.calls.where((c) => c == 'addCandidate'), hasLength(2));
    expect(pair.linkB.calls.where((c) => c == 'addCandidate'), hasLength(2));
  });

  test('the offerer waits until the other phone is ready', () async {
    final pair = Pair();
    addTearDown(pair.dispose);

    await pair.a.startCall();
    await pumpEventQueue();
    expect(pair.a.phase, CallPhase.waitingForPeer);
    expect(pair.wire, <String>['A:call_ready']);
    expect(pair.wire, isNot(contains('A:offer')));
    expect(pair.b.phase, CallPhase.incoming);

    await pair.b.startCall();
    await pumpEventQueue();
    expect(pair.wire, contains('A:offer'));
    expect(pair.a.phase, CallPhase.negotiating);
  });

  test('answerer starting first still gets exactly one offer', () async {
    final pair = Pair();
    addTearDown(pair.dispose);
    await pair.b.startCall();
    await pumpEventQueue();
    expect(pair.a.phase, CallPhase.incoming);
    expect(pair.wire, <String>['B:call_ready']);

    await pair.a.startCall();
    await pumpEventQueue();
    expect(pair.wire.where((e) => e == 'A:offer'), hasLength(1));
    expect(pair.wire.where((e) => e == 'B:offer'), isEmpty);
  });

  test('declining an incoming call ends the other side', () async {
    final pair = Pair();
    addTearDown(pair.dispose);
    await pair.a.startCall();
    await pumpEventQueue();
    expect(pair.b.phase, CallPhase.incoming);

    await pair.b.hangUp();
    await pumpEventQueue();
    expect(pair.wire, contains('B:call_reject'));
    expect(pair.b.phase, CallPhase.ended);
    expect(pair.a.phase, CallPhase.ended);
    expect(pair.a.statusText, contains('declined'));
    expect(pair.linkA.closed, isTrue);
  });

  test('hang up sends call_end and closes only the peer link', () async {
    final pair = await _connectedPair();
    await pair.a.hangUp();
    await pumpEventQueue();
    expect(pair.wire, contains('A:call_end'));
    expect(pair.a.phase, CallPhase.ended);
    expect(pair.b.phase, CallPhase.ended);
    expect(pair.linkA.closed, isTrue);
    expect(pair.linkB.closed, isTrue);
    expect(pair.b.statusText, contains('ended'));
  });

  test('a call can be started again after it ended', () async {
    final pair = await _connectedPair();
    await pair.a.hangUp();
    await pumpEventQueue();
    final firstLinkA = pair.linkA;

    await pair.a.startCall();
    await pair.b.startCall();
    await pumpEventQueue();
    expect(identical(firstLinkA, pair.linkA), isFalse);
    expect(pair.a.phase, CallPhase.negotiating);
    expect(pair.wire.where((e) => e == 'A:offer'), hasLength(2));
  });

  group('unexpected messages are rejected, not applied', () {
    test('an offer sent to the offerer (glare) gets an error', () async {
      final pair = Pair();
      addTearDown(pair.dispose);
      await pair.a.startCall();
      await pumpEventQueue();
      pair.wire.clear();

      await pair.a.onSignal(
        _msg(SignalType.offer, SdpPayload.offer(_fakeSdp).toPayload()),
      );
      expect(pair.wire, <String>['A:error']);
      expect(pair.a.phase, CallPhase.waitingForPeer);
      expect(pair.linkA.calls, isNot(contains('acceptOffer')));
      expect(pair.a.warning, isNotNull);
    });

    test('an answer sent to the answerer is refused', () async {
      final pair = Pair();
      addTearDown(pair.dispose);
      await pair.b.startCall();
      await pumpEventQueue();
      pair.wire.clear();
      await pair.b.onSignal(
        _msg(SignalType.answer, SdpPayload.answer(_fakeSdp).toPayload()),
      );
      expect(pair.wire, <String>['B:error']);
      expect(pair.linkB.calls, isNot(contains('acceptAnswer')));
    });

    test('an answer without a pending offer is out of order', () async {
      final pair = Pair();
      addTearDown(pair.dispose);
      await pair.a.startCall();
      await pumpEventQueue();
      pair.wire.clear();
      await pair.a.onSignal(
        _msg(SignalType.answer, SdpPayload.answer(_fakeSdp).toPayload()),
      );
      expect(pair.wire, <String>['A:error']);
      expect(pair.linkA.calls, isNot(contains('acceptAnswer')));
    });

    test('a second answer is refused', () async {
      final pair = await _connectedPair();
      pair.wire.clear();
      await pair.a.onSignal(
        _msg(SignalType.answer, SdpPayload.answer(_fakeSdp).toPayload()),
      );
      expect(pair.wire, <String>['A:error']);
      expect(pair.linkA.calls.where((c) => c == 'acceptAnswer'), hasLength(1));
    });

    test('a second offer is refused', () async {
      final pair = await _connectedPair();
      pair.wire.clear();
      await pair.b.onSignal(
        _msg(SignalType.offer, SdpPayload.offer(_fakeSdp).toPayload()),
      );
      expect(pair.wire, <String>['B:error']);
      expect(pair.linkB.calls.where((c) => c == 'acceptOffer'), hasLength(1));
    });

    test('an offer before this phone is ready is refused', () async {
      final pair = Pair();
      addTearDown(pair.dispose);
      await pair.b.onSignal(
        _msg(SignalType.offer, SdpPayload.offer(_fakeSdp).toPayload()),
      );
      expect(pair.wire, <String>['B:error']);
      expect(pair.b.phase, CallPhase.idle);
    });

    test('a malformed SDP is refused without ending the call', () async {
      final pair = Pair();
      addTearDown(pair.dispose);
      await pair.b.startCall();
      await pumpEventQueue();
      pair.wire.clear();
      await pair.b.onSignal(
        _msg(SignalType.offer, <String, Object?>{
          'type': 'offer',
          'sdp': 'garbage',
        }),
      );
      expect(pair.wire, <String>['B:error']);
      expect(pair.b.phase, CallPhase.waitingForPeer);
      expect(pair.linkB.calls, isNot(contains('acceptOffer')));
    });

    test('a malformed candidate is refused without ending the call', () async {
      final pair = await _connectedPair();
      pair.wire.clear();
      await pair.a.onSignal(
        _msg(SignalType.candidate, <String, Object?>{'candidate': 'junk'}),
      );
      expect(pair.wire, <String>['A:error']);
      expect(pair.a.phase, CallPhase.connected);
    });

    test('a candidate outside a call is refused', () async {
      final pair = Pair();
      addTearDown(pair.dispose);
      await pair.a.onSignal(
        _msg(SignalType.candidate, _candidate(1).toPayload()),
      );
      expect(pair.wire, <String>['A:error']);
    });

    test('call_ready twice during a call is refused', () async {
      final pair = await _connectedPair();
      pair.wire.clear();
      await pair.a.onSignal(_msg(SignalType.callReady, callReadyPayload()));
      expect(pair.wire, <String>['A:error']);
      expect(pair.a.phase, CallPhase.connected);
    });
  });

  test(
    'candidates that arrive before the offer are queued then applied',
    () async {
      final pair = Pair();
      addTearDown(pair.dispose);
      await pair.b.startCall();
      await pumpEventQueue();

      // Candidates arrive first (out of order) ...
      await pair.b.onSignal(
        _msg(SignalType.candidate, _candidate(1).toPayload()),
      );
      await pair.b.onSignal(
        _msg(SignalType.candidate, _candidate(2).toPayload()),
      );
      expect(pair.linkB.calls, isNot(contains('addCandidate')));

      // ... then the offer. They are applied after the remote description and
      // before the answer is created.
      await pair.b.onSignal(
        _msg(SignalType.offer, SdpPayload.offer(_fakeSdp).toPayload()),
      );
      final calls = pair.linkB.calls;
      expect(calls.where((c) => c == 'addCandidate'), hasLength(2));
      expect(
        calls.indexOf('acceptOffer'),
        lessThan(calls.indexOf('addCandidate')),
      );
      expect(
        calls.indexOf('addCandidate'),
        lessThan(calls.indexOf('createAnswer')),
      );
    },
  );

  test('end-of-candidates markers are ignored', () async {
    final pair = await _connectedPair();
    final before = pair.linkA.calls.where((c) => c == 'addCandidate').length;
    pair.wire.clear();
    await pair.a.onSignal(
      _msg(SignalType.candidate, <String, Object?>{'candidate': ''}),
    );
    expect(pair.wire, isEmpty);
    expect(pair.linkA.calls.where((c) => c == 'addCandidate').length, before);
  });

  group('connection problems are reported honestly', () {
    test('ICE failure fails the call with an explanation', () async {
      final pair = Pair();
      addTearDown(pair.dispose);
      await pair.a.startCall();
      await pair.b.startCall();
      await pumpEventQueue();
      pair.linkA.onConnectionState?.call(LinkConnectionState.failed);
      await pumpEventQueue();
      expect(pair.a.phase, CallPhase.failed);
      expect(pair.a.statusText, contains('network path'));
      expect(pair.linkA.closed, isTrue);
      expect(pair.wire, contains('A:call_end'));
      expect(pair.b.phase, CallPhase.ended);
    });

    test(
      'a failed local setup fails the call and tells nobody it is ready',
      () async {
        var linkCreated = false;
        final sent = <SignalType>[];
        final negotiator = CallNegotiator(
          role: NegotiationRole.offerer,
          linkFactory: () {
            linkCreated = true;
            return FakeLink(failOpen: true);
          },
          send: (type, payload) {
            sent.add(type);
            return CallSendResult.sent;
          },
        );
        addTearDown(negotiator.dispose);
        await negotiator.startCall();
        expect(linkCreated, isTrue);
        expect(negotiator.phase, CallPhase.failed);
        expect(sent, isNot(contains(SignalType.callReady)));
      },
    );

    test('losing signaling stops the call', () async {
      final pair = await _connectedPair();
      await pair.a.onSignalingLost();
      expect(pair.a.phase, CallPhase.failed);
      expect(pair.a.statusText, contains('lost'));
      expect(pair.linkA.closed, isTrue);
      // The lost channel cannot carry a goodbye.
      expect(pair.wire.where((e) => e == 'A:call_end'), isEmpty);
    });

    test('losing signaling while only "incoming" just clears it', () async {
      final pair = Pair();
      addTearDown(pair.dispose);
      await pair.a.startCall();
      await pumpEventQueue();
      expect(pair.b.phase, CallPhase.incoming);
      await pair.b.onSignalingLost();
      expect(pair.b.phase, CallPhase.idle);
    });

    test('no ICE connection in time fails the call', () async {
      final pair = Pair(connectTimeout: const Duration(milliseconds: 80));
      addTearDown(pair.dispose);
      await pair.a.startCall();
      await pair.b.startCall();
      await pumpEventQueue();
      expect(pair.a.phase, CallPhase.negotiating);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(pair.a.phase, CallPhase.failed);
      expect(pair.a.statusText, contains('did not connect'));
    });

    test(
      'ICE disconnect moves back to connecting, recovery to connected',
      () async {
        final pair = await _connectedPair();
        pair.linkA.onConnectionState?.call(LinkConnectionState.disconnected);
        expect(pair.a.phase, CallPhase.connecting);
        expect(pair.a.milestones.iceConnected, isFalse);
        pair.linkA.onConnectionState?.call(LinkConnectionState.connected);
        expect(pair.a.phase, CallPhase.connected);
        expect(pair.a.milestones.iceConnected, isTrue);
      },
    );

    test('the offer is refused when the channel cannot carry it', () async {
      final negotiator = CallNegotiator(
        role: NegotiationRole.offerer,
        linkFactory: () => FakeLink(),
        send: (type, payload) => type == SignalType.offer
            ? CallSendResult.tooLarge
            : CallSendResult.sent,
      );
      addTearDown(negotiator.dispose);
      await negotiator.startCall();
      await negotiator.onSignal(_msg(SignalType.callReady, callReadyPayload()));
      await pumpEventQueue();
      expect(negotiator.phase, CallPhase.failed);
      expect(negotiator.statusText, contains('too large'));
    });
  });

  test('late events from a finished call are ignored', () async {
    final pair = await _connectedPair();
    final oldLink = pair.linkA;
    await pair.a.hangUp();
    await pumpEventQueue();
    // The link's callbacks were detached; nothing may change the state.
    oldLink.onConnectionState?.call(LinkConnectionState.connected);
    oldLink.onMediaSnapshot?.call(const MediaSnapshot(receivedVideoFrames: 10));
    expect(pair.a.phase, CallPhase.ended);
    expect(pair.a.milestones.remoteVideoFrames, isFalse);
  });

  group('reconnecting state and repeated termination (Phase 4)', () {
    test(
      'isReconnecting is true only between a disconnect and recovery',
      () async {
        final pair = await _connectedPair();
        expect(pair.a.isReconnecting, isFalse);
        pair.linkA.onConnectionState?.call(LinkConnectionState.disconnected);
        expect(pair.a.isReconnecting, isTrue);
        pair.linkA.onConnectionState?.call(LinkConnectionState.connected);
        expect(pair.a.isReconnecting, isFalse);
        expect(pair.a.phase, CallPhase.connected);
      },
    );

    test(
      'when the grace period ends the call fails, not "reconnecting"',
      () async {
        final pair = await _connectedPair(
          using: Pair(disconnectGrace: const Duration(milliseconds: 60)),
        );
        pair.linkA.onConnectionState?.call(LinkConnectionState.disconnected);
        expect(pair.a.isReconnecting, isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(pair.a.phase, CallPhase.failed);
        expect(pair.a.isReconnecting, isFalse);
        expect(pair.linkA.closed, isTrue);
      },
    );

    test('hanging up twice sends one call_end and is harmless', () async {
      final pair = await _connectedPair();
      await pair.a.hangUp();
      await pair.a.hangUp();
      await pumpEventQueue();
      expect(pair.wire.where((e) => e == 'A:call_end'), hasLength(1));
      expect(pair.a.phase, CallPhase.ended);
      expect(pair.b.phase, CallPhase.ended);
    });

    test(
      'shutdown and dispose can be repeated without closing twice',
      () async {
        final pair = await _connectedPair();
        await pair.a.shutdown();
        await pair.a.shutdown();
        pair.a.dispose();
        pair.a.dispose();
        expect(pair.linkA.calls.where((c) => c == 'close'), hasLength(1));
      },
    );
  });
}

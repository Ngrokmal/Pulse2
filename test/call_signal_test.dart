// Pure Dart tests: message payloads, candidate queue, state rules, stats.
// They do not use the camera, microphone or native WebRTC.
// ignore_for_file: avoid_relative_lib_imports
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../lib/features/video_call/models/call_signal.dart';
import '../lib/features/video_call/models/call_state.dart';
import '../lib/features/video_call/models/signal_message.dart';
import '../lib/features/video_call/services/local_signal_service.dart';

const String _sdp = 'v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n';
const String _candidateLine =
    'candidate:1 1 udp 2122260223 192.0.2.10 40000 typ host generation 0';

SignalMessage _message(SignalType type, Map<String, Object?> payload) {
  return SignalMessage(
    type: type,
    sessionId: 'session',
    senderId: 'sender',
    payload: payload,
  );
}

void main() {
  group('call message types', () {
    test('survive encode and decode with the Phase 2 envelope', () {
      for (final type in kCallSignalTypes) {
        final decoded = SignalMessage.decode(
          _message(type, <String, Object?>{'x': 1}).encode(),
        );
        expect(decoded.type, type);
        expect(decoded.version, kSignalProtocolVersion);
        expect(decoded.sessionId, 'session');
        expect(decoded.senderId, 'sender');
      }
    });

    test('wire names are the documented ones', () {
      expect(SignalType.offer.wireName, 'offer');
      expect(SignalType.answer.wireName, 'answer');
      expect(SignalType.candidate.wireName, 'candidate');
      expect(SignalType.callReady.wireName, 'call_ready');
      expect(SignalType.callReject.wireName, 'call_reject');
      expect(SignalType.callEnd.wireName, 'call_end');
    });

    test('unknown call-like type names are still rejected', () {
      final raw = jsonEncode(<String, Object?>{
        'v': kSignalProtocolVersion,
        'type': 'call_start',
        'session': 's',
        'sender': 'x',
        'payload': <String, Object?>{},
      });
      expect(
        () => SignalMessage.decode(raw),
        throwsA(isA<SignalFormatException>()),
      );
    });

    test('isCallSignal separates call types from Phase 2 types', () {
      expect(isCallSignal(SignalType.offer), isTrue);
      expect(isCallSignal(SignalType.chat), isFalse);
      expect(isCallSignal(SignalType.hello), isFalse);
      expect(isCallSignal(SignalType.error), isFalse);
    });
  });

  group('SDP payload', () {
    test('offer round-trips', () {
      final message = _message(
        SignalType.offer,
        SdpPayload.offer(_sdp).toPayload(),
      );
      final decoded = SignalMessage.decode(message.encode());
      final payload = SdpPayload.fromMessage(decoded);
      expect(payload.type, SignalType.offer);
      expect(payload.sdp, _sdp);
    });

    test('answer round-trips', () {
      final payload = SdpPayload.fromMessage(
        _message(SignalType.answer, SdpPayload.answer(_sdp).toPayload()),
      );
      expect(payload.type, SignalType.answer);
    });

    test('missing, empty or non-string sdp is rejected', () {
      for (final bad in <Object?>[
        null,
        '',
        42,
        <String>['v=0'],
      ]) {
        expect(
          () => SdpPayload.fromMessage(
            _message(SignalType.offer, <String, Object?>{
              'type': 'offer',
              'sdp': bad,
            }),
          ),
          throwsA(isA<CallSignalException>()),
          reason: 'sdp: $bad',
        );
      }
    });

    test('declared type must match the message type', () {
      expect(
        () => SdpPayload.fromMessage(
          _message(SignalType.offer, <String, Object?>{
            'type': 'answer',
            'sdp': _sdp,
          }),
        ),
        throwsA(
          isA<CallSignalException>().having(
            (e) => e.code,
            'code',
            CallErrorCode.invalidSdp,
          ),
        ),
      );
    });

    test('text that is not an SDP or is too large is rejected', () {
      expect(
        () => SdpPayload.fromMessage(
          _message(SignalType.offer, <String, Object?>{
            'type': 'offer',
            'sdp': 'hello',
          }),
        ),
        throwsA(isA<CallSignalException>()),
      );
      expect(
        () => SdpPayload.fromMessage(
          _message(SignalType.offer, <String, Object?>{
            'type': 'offer',
            'sdp': 'v=0${'a' * kMaxSdpChars}',
          }),
        ),
        throwsA(isA<CallSignalException>()),
      );
    });

    test('a non-SDP message type is rejected', () {
      expect(
        () => SdpPayload.fromMessage(_message(SignalType.chat, {})),
        throwsA(isA<CallSignalException>()),
      );
    });
  });

  group('ICE candidate payload', () {
    test('round-trips with sdpMid and index', () {
      const original = IceCandidatePayload(
        candidate: _candidateLine,
        sdpMid: '0',
        sdpMLineIndex: 0,
      );
      final decoded = SignalMessage.decode(
        _message(SignalType.candidate, original.toPayload()).encode(),
      );
      final parsed = IceCandidatePayload.fromMessage(decoded);
      expect(parsed.candidate, _candidateLine);
      expect(parsed.sdpMid, '0');
      expect(parsed.sdpMLineIndex, 0);
      expect(parsed.candidateType, 'host');
      expect(parsed.isEndOfCandidates, isFalse);
    });

    test('an empty candidate means end of candidates', () {
      final parsed = IceCandidatePayload.fromMessage(
        _message(SignalType.candidate, <String, Object?>{'candidate': ''}),
      );
      expect(parsed.isEndOfCandidates, isTrue);
    });

    test('malformed fields are rejected', () {
      final cases = <Map<String, Object?>>[
        <String, Object?>{},
        <String, Object?>{'candidate': 5, 'sdpMid': '0'},
        <String, Object?>{'candidate': 'not-a-candidate', 'sdpMid': '0'},
        <String, Object?>{'candidate': _candidateLine},
        <String, Object?>{'candidate': _candidateLine, 'sdpMid': 7},
        <String, Object?>{'candidate': _candidateLine, 'sdpMLineIndex': '0'},
        <String, Object?>{'candidate': _candidateLine, 'sdpMLineIndex': -1},
        <String, Object?>{
          'candidate': 'candidate:${'1' * kMaxCandidateChars}',
          'sdpMid': '0',
        },
      ];
      for (final payload in cases) {
        expect(
          () => IceCandidatePayload.fromMessage(
            _message(SignalType.candidate, payload),
          ),
          throwsA(isA<CallSignalException>()),
          reason: '$payload',
        );
      }
    });

    test('a non-candidate message type is rejected', () {
      expect(
        () => IceCandidatePayload.fromMessage(_message(SignalType.offer, {})),
        throwsA(isA<CallSignalException>()),
      );
    });
  });

  group('reasons', () {
    test('callReasonOf accepts short text and defaults otherwise', () {
      expect(
        callReasonOf(_message(SignalType.callEnd, {'reason': 'hangup'})),
        'hangup',
      );
      expect(callReasonOf(_message(SignalType.callEnd, {})), 'unspecified');
      expect(
        callReasonOf(_message(SignalType.callEnd, {'reason': 'x' * 200})),
        'unspecified',
      );
      expect(
        callReasonOf(_message(SignalType.callEnd, {'reason': 5})),
        'unspecified',
      );
    });
  });

  group('negotiation role', () {
    test('the Host offers and the joining phone answers', () {
      expect(negotiationRoleFor(SignalRole.host), NegotiationRole.offerer);
      expect(negotiationRoleFor(SignalRole.client), NegotiationRole.answerer);
    });
  });

  group('PendingCandidateQueue', () {
    const a = IceCandidatePayload(candidate: _candidateLine, sdpMid: '0');
    const b = IceCandidatePayload(candidate: _candidateLine, sdpMid: '1');

    test('queues until the remote description is installed, then drains', () {
      final queue = PendingCandidateQueue();
      expect(queue.submit(a), isFalse);
      expect(queue.submit(b), isFalse);
      expect(queue.length, 2);
      expect(queue.isOpen, isFalse);

      final drained = queue.open();
      expect(drained, <IceCandidatePayload>[a, b]);
      expect(queue.length, 0);
      expect(queue.isOpen, isTrue);
      expect(queue.submit(a), isTrue);
    });

    test('reset starts over', () {
      final queue = PendingCandidateQueue()
        ..submit(a)
        ..open()
        ..reset();
      expect(queue.isOpen, isFalse);
      expect(queue.length, 0);
    });

    test('refuses an unbounded backlog', () {
      final queue = PendingCandidateQueue(maxQueued: 2)
        ..submit(a)
        ..submit(b);
      expect(() => queue.submit(a), throwsA(isA<CallSignalException>()));
    });
  });

  group('CallPhase transitions', () {
    test('the normal path is allowed step by step', () {
      const path = <CallPhase>[
        CallPhase.idle,
        CallPhase.preparing,
        CallPhase.waitingForPeer,
        CallPhase.negotiating,
        CallPhase.connecting,
        CallPhase.connected,
        CallPhase.mediaFlowing,
        CallPhase.ended,
        CallPhase.idle,
      ];
      for (var i = 0; i < path.length - 1; i++) {
        expect(
          path[i].canMoveTo(path[i + 1]),
          isTrue,
          reason: '${path[i]} -> ${path[i + 1]}',
        );
      }
    });

    test('media cannot be "flowing" before ICE connected', () {
      expect(CallPhase.negotiating.canMoveTo(CallPhase.mediaFlowing), isFalse);
      expect(CallPhase.connecting.canMoveTo(CallPhase.mediaFlowing), isFalse);
      expect(CallPhase.idle.canMoveTo(CallPhase.connected), isFalse);
      expect(CallPhase.waitingForPeer.canMoveTo(CallPhase.connected), isFalse);
    });

    test('every active phase can end or fail', () {
      for (final phase in CallPhase.values.where((p) => p.isActive)) {
        expect(phase.canMoveTo(CallPhase.ended), isTrue, reason: '$phase');
        expect(phase.canMoveTo(CallPhase.failed), isTrue, reason: '$phase');
      }
    });

    test('terminal phases only restart', () {
      expect(CallPhase.ended.canMoveTo(CallPhase.negotiating), isFalse);
      expect(CallPhase.failed.canMoveTo(CallPhase.connected), isFalse);
      expect(CallPhase.failed.canMoveTo(CallPhase.preparing), isTrue);
    });

    test('a lost ICE path can recover from connected', () {
      expect(CallPhase.connected.canMoveTo(CallPhase.connecting), isTrue);
      expect(CallPhase.mediaFlowing.canMoveTo(CallPhase.connecting), isTrue);
    });
  });

  group('MediaSnapshot.fromStats', () {
    test('reads received and sent video and audio', () {
      final snapshot = MediaSnapshot.fromStats(const <RawStat>[
        RawStat('inbound-rtp', <Object?, Object?>{
          'kind': 'video',
          'framesDecoded': 120,
          'frameWidth': 1280,
          'frameHeight': 720,
          'framesPerSecond': 29.5,
        }),
        RawStat('inbound-rtp', <Object?, Object?>{
          'mediaType': 'audio',
          'bytesReceived': '4096',
        }),
        RawStat('outbound-rtp', <Object?, Object?>{
          'kind': 'video',
          'bytesSent': 90000,
          'frameWidth': 1280,
          'frameHeight': 720,
        }),
        RawStat('outbound-rtp', <Object?, Object?>{
          'kind': 'audio',
          'bytesSent': 2000,
        }),
        RawStat('candidate-pair', <Object?, Object?>{'bytesSent': 99}),
      ]);
      expect(snapshot.receivedVideoFrames, 120);
      expect(snapshot.receivedWidth, 1280);
      expect(snapshot.receivedHeight, 720);
      expect(snapshot.receivedFps, 29.5);
      expect(snapshot.receivedAudioBytes, 4096);
      expect(snapshot.sentVideoBytes, 90000);
      expect(snapshot.sentAudioBytes, 2000);
      expect(snapshot.describe(), contains('1280x720'));
    });

    test('empty or odd stats give an empty snapshot, not an error', () {
      expect(MediaSnapshot.fromStats(const <RawStat>[]), MediaSnapshot.empty);
      final odd = MediaSnapshot.fromStats(const <RawStat>[
        RawStat('inbound-rtp', <Object?, Object?>{
          'kind': 'video',
          'framesDecoded': 'not a number',
        }),
      ]);
      expect(odd.receivedVideoFrames, 0);
      expect(odd.describe(), contains('No remote video frames yet'));
    });
  });
}

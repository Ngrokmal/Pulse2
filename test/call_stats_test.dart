// Parsing and arithmetic tests with FAKE statistics. They prove the maths and
// the handling of missing values; they say nothing about real network or
// device performance.
// ignore_for_file: avoid_relative_lib_imports
import 'package:flutter_test/flutter_test.dart';

import '../lib/features/video_call/models/call_state.dart';
import '../lib/features/video_call/models/call_stats.dart';
import '../lib/features/video_call/models/diagnostics_format.dart';

RawStat _rtp(
  String type,
  String kind,
  Map<Object?, Object?> values, {
  String? id,
}) => RawStat(type, <Object?, Object?>{'kind': kind, ...values}, id: id);

CallStatsSample _sample(
  int t, {
  double? txVideoBytes,
  double? txVideoPackets,
  double? txVideoFrames,
  double? txVideoFps,
  double? rxVideoBytes,
  double? rxVideoPackets,
  double? rxVideoLost,
  double? rxVideoFrames,
  double? rxVideoFps,
  double? txAudioBytes,
  double? rxAudioBytes,
  double? rxAudioPackets,
  double? rxAudioLost,
  double? remoteLost,
}) {
  return CallStatsSample(
    timestampMs: t,
    txVideoBytes: txVideoBytes,
    txVideoPackets: txVideoPackets,
    txVideoFrames: txVideoFrames,
    txVideoFps: txVideoFps,
    rxVideoBytes: rxVideoBytes,
    rxVideoPackets: rxVideoPackets,
    rxVideoPacketsLost: rxVideoLost,
    rxVideoFrames: rxVideoFrames,
    rxVideoFps: rxVideoFps,
    txAudioBytes: txAudioBytes,
    rxAudioBytes: rxAudioBytes,
    rxAudioPackets: rxAudioPackets,
    rxAudioPacketsLost: rxAudioLost,
    remoteVideoPacketsLost: remoteLost,
  );
}

void main() {
  const parser = CallStatsParser();

  group('statNumber', () {
    test('accepts numbers and numeric strings', () {
      expect(statNumber(5), 5.0);
      expect(statNumber(2.5), 2.5);
      expect(statNumber('4096'), 4096.0);
    });

    test('rejects missing, non-numeric, NaN and infinite values', () {
      expect(statNumber(null), isNull);
      expect(statNumber('abc'), isNull);
      expect(statNumber(true), isNull);
      expect(statNumber(double.nan), isNull);
      expect(statNumber(double.infinity), isNull);
      expect(statNumber(<int>[1]), isNull);
    });
  });

  group('CallStatsParser', () {
    final full = <RawStat>[
      _rtp('outbound-rtp', 'video', <Object?, Object?>{
        'bytesSent': 500000,
        'packetsSent': 600,
        'framesEncoded': 300,
        'frameWidth': 1280,
        'frameHeight': 720,
        'framesPerSecond': 29.5,
        'qualityLimitationReason': 'none',
        'encoderImplementation': 'libvpx',
        'codecId': 'C1',
      }),
      _rtp('outbound-rtp', 'audio', <Object?, Object?>{'bytesSent': 8000}),
      _rtp('inbound-rtp', 'video', <Object?, Object?>{
        'bytesReceived': 400000,
        'packetsReceived': 500,
        'packetsLost': 5,
        'framesDecoded': 250,
        'frameWidth': 960,
        'frameHeight': 540,
        'framesPerSecond': 24,
        'jitter': 0.012,
        'decoderImplementation': 'MediaCodec',
        'codecId': 'C1',
      }),
      _rtp('inbound-rtp', 'audio', <Object?, Object?>{
        'bytesReceived': 7000,
        'packetsReceived': 340,
        'packetsLost': 2,
        'jitter': 0.02,
      }),
      _rtp('remote-inbound-rtp', 'video', <Object?, Object?>{
        'packetsLost': 3,
        'roundTripTime': 0.05,
      }),
      const RawStat('codec', <Object?, Object?>{
        'mimeType': 'video/VP8',
      }, id: 'C1'),
      const RawStat('transport', <Object?, Object?>{
        'selectedCandidatePairId': 'P1',
      }, id: 'T1'),
      const RawStat('candidate-pair', <Object?, Object?>{
        'state': 'succeeded',
        'currentRoundTripTime': 0.004,
        'availableOutgoingBitrate': 3000000,
        'bytesSent': 600000,
        'bytesReceived': 450000,
        'localCandidateId': 'L1',
        'remoteCandidateId': 'R1',
      }, id: 'P1'),
      const RawStat('local-candidate', <Object?, Object?>{
        'candidateType': 'host',
        'protocol': 'udp',
        'networkType': 'wifi',
        'ip': '192.0.2.10',
      }, id: 'L1'),
      const RawStat('remote-candidate', <Object?, Object?>{
        'candidateType': 'host',
        'ip': '192.0.2.11',
      }, id: 'R1'),
    ];

    test('reads every field it needs from a complete report', () {
      final s = parser.parse(full, timestampMs: 1234);
      expect(s.timestampMs, 1234);
      expect(s.txVideoBytes, 500000);
      expect(s.txVideoPackets, 600);
      expect(s.txVideoWidth, 1280);
      expect(s.txVideoHeight, 720);
      expect(s.txVideoFps, 29.5);
      expect(s.txQualityLimitation, 'none');
      expect(s.txEncoder, 'libvpx');
      expect(s.txVideoCodec, 'VP8');
      expect(s.txAudioBytes, 8000);
      expect(s.rxVideoBytes, 400000);
      expect(s.rxVideoPacketsLost, 5);
      expect(s.rxVideoWidth, 960);
      expect(s.rxVideoHeight, 540);
      expect(s.rxVideoFps, 24);
      expect(s.rxVideoJitterMs, closeTo(12, 1e-9));
      expect(s.rxDecoder, 'MediaCodec');
      expect(s.rxVideoCodec, 'VP8');
      expect(s.rxAudioBytes, 7000);
      expect(s.rxAudioJitterMs, closeTo(20, 1e-9));
      expect(s.remoteVideoPacketsLost, 3);
      expect(s.remoteVideoRttMs, closeTo(50, 1e-9));
    });

    test('reads the selected candidate pair but keeps no address', () {
      final s = parser.parse(full, timestampMs: 0);
      expect(s.pairRttMs, closeTo(4, 1e-9));
      expect(s.availableOutgoingKbps, closeTo(3000, 1e-9));
      expect(s.pairBytesSent, 600000);
      expect(s.pairBytesReceived, 450000);
      expect(s.localCandidateType, 'host');
      expect(s.remoteCandidateType, 'host');
      expect(s.candidateProtocol, 'udp');
      expect(s.networkType, 'wifi');
    });

    test('falls back to a nominated, succeeded pair without a transport', () {
      final s = parser.parse(const <RawStat>[
        RawStat('candidate-pair', <Object?, Object?>{
          'state': 'in-progress',
          'currentRoundTripTime': 9.0,
        }),
        RawStat('candidate-pair', <Object?, Object?>{
          'state': 'succeeded',
          'nominated': true,
          'currentRoundTripTime': 0.02,
        }),
      ], timestampMs: 0);
      expect(s.pairRttMs, closeTo(20, 1e-9));
    });

    test('no selected pair means no pair values', () {
      final s = parser.parse(const <RawStat>[
        RawStat('candidate-pair', <Object?, Object?>{
          'state': 'waiting',
          'currentRoundTripTime': 0.5,
        }),
      ], timestampMs: 0);
      expect(s.pairRttMs, isNull);
      expect(s.localCandidateType, isNull);
    });

    test('an empty report gives all-null fields instead of zeros', () {
      final s = parser.parse(const <RawStat>[], timestampMs: 5);
      expect(s.txVideoBytes, isNull);
      expect(s.rxVideoBytes, isNull);
      expect(s.rxVideoFps, isNull);
      expect(s.pairRttMs, isNull);
      expect(s.txEncoder, isNull);
    });

    test('invalid values become null', () {
      final s = parser.parse(<RawStat>[
        _rtp('outbound-rtp', 'video', <Object?, Object?>{
          'bytesSent': 'lots',
          'frameWidth': 'wide',
          'frameHeight': 720,
          'framesPerSecond': double.nan,
        }),
        _rtp('inbound-rtp', 'video', <Object?, Object?>{
          'bytesReceived': null,
          'jitter': double.infinity,
        }),
      ], timestampMs: 0);
      expect(s.txVideoBytes, isNull);
      expect(s.txVideoWidth, isNull);
      expect(s.txVideoFps, isNull);
      expect(s.rxVideoBytes, isNull);
      expect(s.rxVideoJitterMs, isNull);
    });

    test('entries without a kind are ignored', () {
      final s = parser.parse(const <RawStat>[
        RawStat('inbound-rtp', <Object?, Object?>{'bytesReceived': 99}),
      ], timestampMs: 0);
      expect(s.rxVideoBytes, isNull);
      expect(s.rxAudioBytes, isNull);
    });

    test(
      'counters of several video streams are added, size is the largest',
      () {
        final s = parser.parse(<RawStat>[
          _rtp('outbound-rtp', 'video', <Object?, Object?>{
            'bytesSent': 100,
            'frameWidth': 640,
            'frameHeight': 360,
          }),
          _rtp('outbound-rtp', 'video', <Object?, Object?>{
            'bytesSent': 300,
            'frameWidth': 1280,
            'frameHeight': 720,
          }),
        ], timestampMs: 0);
        expect(s.txVideoBytes, 400);
        expect(s.txVideoWidth, 1280);
        expect(s.txVideoHeight, 720);
      },
    );
  });

  group('CallStatsTracker rates', () {
    test('the first sample has no rates and is not a valid interval', () {
      final tracker = CallStatsTracker();
      final m = tracker.add(_sample(0, txVideoBytes: 1000));
      expect(m.intervalValid, isFalse);
      expect(m.txVideoKbps, isNull);
    });

    test('bitrate comes from the byte difference over elapsed time', () {
      final tracker = CallStatsTracker();
      tracker.add(_sample(0, txVideoBytes: 1000, rxVideoBytes: 0));
      // 250000 bytes in 2 s = 1000 kbit/s.
      final m = tracker.add(
        _sample(2000, txVideoBytes: 251000, rxVideoBytes: 125000),
      );
      expect(m.intervalValid, isTrue);
      expect(m.txVideoKbps, closeTo(1000, 1e-9));
      expect(m.rxVideoKbps, closeTo(500, 1e-9));
    });

    test('a missing counter gives an unavailable rate, not zero', () {
      final tracker = CallStatsTracker();
      tracker.add(_sample(0, txVideoBytes: 1000));
      final m = tracker.add(_sample(2000, txVideoBytes: 2000));
      expect(m.txVideoKbps, isNotNull);
      expect(m.rxVideoKbps, isNull);
      expect(m.txAudioKbps, isNull);
    });

    test('a timestamp that did not advance keeps the old baseline', () {
      final tracker = CallStatsTracker();
      tracker.add(_sample(1000, txVideoBytes: 0));
      final same = tracker.add(_sample(1000, txVideoBytes: 999));
      expect(same.intervalValid, isFalse);
      expect(same.txVideoKbps, isNull);
      final next = tracker.add(_sample(3000, txVideoBytes: 250000));
      expect(next.txVideoKbps, closeTo(1000, 1e-9));
    });

    test('an earlier timestamp is rejected without a negative rate', () {
      final tracker = CallStatsTracker();
      tracker.add(_sample(5000, txVideoBytes: 0));
      final m = tracker.add(_sample(4000, txVideoBytes: 500));
      expect(m.intervalValid, isFalse);
      expect(m.txVideoKbps, isNull);
    });

    test(
      'a counter that went backwards is unavailable (connection replaced)',
      () {
        final tracker = CallStatsTracker();
        tracker.add(_sample(0, txVideoBytes: 900000));
        final m = tracker.add(_sample(2000, txVideoBytes: 1000));
        expect(m.intervalValid, isTrue);
        expect(m.txVideoKbps, isNull);
      },
    );

    test('a very long gap gives no rates, the next interval works again', () {
      final tracker = CallStatsTracker();
      tracker.add(_sample(0, txVideoBytes: 0));
      final gap = tracker.add(_sample(60000, txVideoBytes: 1000000));
      expect(gap.intervalValid, isFalse);
      expect(gap.txVideoKbps, isNull);
      final next = tracker.add(_sample(62000, txVideoBytes: 1250000));
      expect(next.intervalValid, isTrue);
      expect(next.txVideoKbps, closeTo(1000, 1e-9));
    });

    test('too short an interval is not used for rates', () {
      final tracker = CallStatsTracker();
      tracker.add(_sample(0, txVideoBytes: 0));
      final m = tracker.add(_sample(100, txVideoBytes: 1000));
      expect(m.intervalValid, isFalse);
      expect(m.txVideoKbps, isNull);
    });

    test('reset forgets the baseline', () {
      final tracker = CallStatsTracker();
      tracker.add(_sample(0, txVideoBytes: 0));
      expect(tracker.hasBaseline, isTrue);
      tracker.reset();
      expect(tracker.hasBaseline, isFalse);
      final m = tracker.add(_sample(2000, txVideoBytes: 250000));
      expect(m.intervalValid, isFalse);
      expect(m.txVideoKbps, isNull);
    });
  });

  group('CallStatsTracker loss, fps and stalls', () {
    test('inbound loss is lost / (received + lost) over the interval', () {
      final tracker = CallStatsTracker();
      tracker.add(_sample(0, rxVideoPackets: 100, rxVideoLost: 10));
      final m = tracker.add(
        _sample(2000, rxVideoPackets: 1000, rxVideoLost: 110),
      );
      // 900 received, 100 lost in the interval.
      expect(m.rxVideoLossPct, closeTo(10, 1e-9));
    });

    test('no packets in the interval is unavailable, not 0 % loss', () {
      final tracker = CallStatsTracker();
      tracker.add(_sample(0, rxVideoPackets: 100, rxVideoLost: 1));
      final m = tracker.add(_sample(2000, rxVideoPackets: 100, rxVideoLost: 1));
      expect(m.rxVideoLossPct, isNull);
    });

    test('a shrinking lost counter counts as no loss, never negative', () {
      final tracker = CallStatsTracker();
      tracker.add(_sample(0, rxVideoPackets: 100, rxVideoLost: 10));
      final m = tracker.add(_sample(2000, rxVideoPackets: 200, rxVideoLost: 8));
      expect(m.rxVideoLossPct, 0);
    });

    test('a packet counter that went backwards gives no loss value', () {
      final tracker = CallStatsTracker();
      tracker.add(_sample(0, rxVideoPackets: 500, rxVideoLost: 0));
      final m = tracker.add(_sample(2000, rxVideoPackets: 10, rxVideoLost: 0));
      expect(m.rxVideoLossPct, isNull);
    });

    test('outbound loss uses packets sent as the denominator', () {
      final tracker = CallStatsTracker();
      tracker.add(_sample(0, txVideoPackets: 0, remoteLost: 0));
      final m = tracker.add(
        _sample(2000, txVideoPackets: 1000, remoteLost: 50),
      );
      expect(m.outboundLossPct, closeTo(5, 1e-9));
    });

    test('the worst of audio and video loss is reported', () {
      final tracker = CallStatsTracker();
      tracker.add(
        _sample(
          0,
          rxVideoPackets: 0,
          rxVideoLost: 0,
          rxAudioPackets: 0,
          rxAudioLost: 0,
        ),
      );
      final m = tracker.add(
        _sample(
          2000,
          rxVideoPackets: 990,
          rxVideoLost: 10,
          rxAudioPackets: 900,
          rxAudioLost: 100,
        ),
      );
      expect(m.rxVideoLossPct, closeTo(1, 1e-9));
      expect(m.rxAudioLossPct, closeTo(10, 1e-9));
      expect(m.worstRxLossPct, closeTo(10, 1e-9));
    });

    test('fps prefers the reported value, else frames per second', () {
      final tracker = CallStatsTracker();
      tracker.add(_sample(0, rxVideoFrames: 100, txVideoFrames: 0));
      final m = tracker.add(
        _sample(2000, rxVideoFrames: 160, txVideoFrames: 0),
      );
      expect(m.rxVideoFps, closeTo(30, 1e-9));

      final tracker2 = CallStatsTracker();
      tracker2.add(_sample(0, rxVideoFrames: 100));
      final reported = tracker2.add(
        _sample(2000, rxVideoFrames: 160, rxVideoFps: 24),
      );
      expect(reported.rxVideoFps, 24);
    });

    test('no received bytes over a valid interval is a stall', () {
      final tracker = CallStatsTracker();
      tracker.add(_sample(0, rxVideoBytes: 5000, rxAudioBytes: 800));
      final stalled = tracker.add(
        _sample(2000, rxVideoBytes: 5000, rxAudioBytes: 800),
      );
      expect(stalled.rxStalled, isTrue);
      final flowing = tracker.add(
        _sample(4000, rxVideoBytes: 9000, rxAudioBytes: 800),
      );
      expect(flowing.rxStalled, isFalse);
    });

    test('missing byte counters never count as a stall', () {
      final tracker = CallStatsTracker();
      tracker.add(_sample(0));
      final m = tracker.add(_sample(2000));
      expect(m.rxStalled, isFalse);
      expect(m.rxBytesDelta, isNull);
    });

    test('a sample with only null fields yields only unavailable values', () {
      final tracker = CallStatsTracker();
      tracker.add(_sample(0));
      final m = tracker.add(_sample(2000));
      expect(m.txVideoKbps, isNull);
      expect(m.rxVideoLossPct, isNull);
      expect(m.rttMs, isNull);
      expect(m.jitterMs, isNull);
      expect(m.hasQualityData, isFalse);
    });

    test('RTT and jitter come from the latest sample; negative is dropped', () {
      final tracker = CallStatsTracker();
      final m = tracker.add(
        const CallStatsSample(
          timestampMs: 0,
          pairRttMs: 12,
          rxVideoJitterMs: 5,
          rxAudioJitterMs: 9,
        ),
      );
      expect(m.rttMs, 12);
      expect(m.jitterMs, 9);
      final bad = CallStatsTracker().add(
        const CallStatsSample(
          timestampMs: 0,
          pairRttMs: -3,
          rxVideoJitterMs: -1,
        ),
      );
      expect(bad.rttMs, isNull);
      expect(bad.jitterMs, isNull);
    });
  });

  group('DiagnosticsFormat', () {
    test('missing values show a dash, never 0', () {
      expect(DiagnosticsFormat.kbps(null), DiagnosticsFormat.unavailable);
      expect(DiagnosticsFormat.percent(null), DiagnosticsFormat.unavailable);
      expect(
        DiagnosticsFormat.milliseconds(null),
        DiagnosticsFormat.unavailable,
      );
      expect(DiagnosticsFormat.fps(null), DiagnosticsFormat.unavailable);
      expect(DiagnosticsFormat.size(null, 720), DiagnosticsFormat.unavailable);
      expect(DiagnosticsFormat.size(0, 0), DiagnosticsFormat.unavailable);
      expect(DiagnosticsFormat.bytes(null), DiagnosticsFormat.unavailable);
      expect(DiagnosticsFormat.text(''), DiagnosticsFormat.unavailable);
    });

    test('real values are formatted', () {
      expect(DiagnosticsFormat.kbps(850), '850 kbit/s');
      expect(DiagnosticsFormat.kbps(2500), '2.50 Mbit/s');
      expect(DiagnosticsFormat.percent(0), '0.0 %');
      expect(DiagnosticsFormat.milliseconds(12.4), '12 ms');
      expect(DiagnosticsFormat.size(1280, 720), '1280x720');
      expect(DiagnosticsFormat.bytes(2048), '2 KB');
    });
  });
}

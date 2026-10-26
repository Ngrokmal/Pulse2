// Quality-state logic with FAKE metrics: thresholds, hysteresis and
// connection overrides. These tests do not measure any real network.
// ignore_for_file: avoid_relative_lib_imports
import 'package:flutter_test/flutter_test.dart';

import '../lib/features/video_call/models/call_quality.dart';
import '../lib/features/video_call/models/call_stats.dart';

CallMetrics _m({
  double? loss,
  double? outLoss,
  double? rtt,
  double? jitter,
  String? limit,
  bool stalled = false,
  double? bytes,
}) {
  return CallMetrics(
    intervalValid: true,
    rxVideoLossPct: loss,
    outboundLossPct: outLoss,
    rttMs: rtt,
    jitterMs: jitter,
    qualityLimitation: limit,
    rxStalled: stalled,
    rxBytesDelta: bytes ?? (stalled ? 0 : 1000),
  );
}

CallMetrics get _good => _m(loss: 0, rtt: 5, jitter: 3);
CallMetrics get _fair => _m(loss: 3, rtt: 5, jitter: 3);
CallMetrics get _poor => _m(loss: 12, rtt: 5, jitter: 3);

QualityEvaluator _connected({
  QualityThresholds thresholds = const QualityThresholds(),
  QualityScope scope = QualityScope.overall,
}) {
  final e = QualityEvaluator(thresholds: thresholds, scope: scope);
  e.setLink(CallLinkState.connected);
  return e;
}

void _feed(QualityEvaluator e, CallMetrics m, int times) {
  for (var i = 0; i < times; i++) {
    e.onMetrics(m);
  }
}

void main() {
  group('grading one sample', () {
    test('thresholds are inclusive at the lower bound of each grade', () {
      CallQuality grade(CallMetrics m) => _connected().onMetrics(m).quality;
      expect(grade(_m(loss: 1.9, rtt: 10)), CallQuality.good);
      expect(grade(_m(loss: 2.0, rtt: 10)), CallQuality.fair);
      expect(grade(_m(loss: 7.9, rtt: 10)), CallQuality.fair);
      expect(grade(_m(loss: 8.0, rtt: 10)), CallQuality.poor);
      expect(grade(_m(loss: 0, rtt: 149)), CallQuality.good);
      expect(grade(_m(loss: 0, rtt: 150)), CallQuality.fair);
      expect(grade(_m(loss: 0, rtt: 400)), CallQuality.poor);
      expect(grade(_m(loss: 0, rtt: 10, jitter: 30)), CallQuality.fair);
      expect(grade(_m(loss: 0, rtt: 10, jitter: 100)), CallQuality.poor);
    });

    test('thresholds are configurable', () {
      final strict = QualityThresholds(fairLossPct: 0.5, poorLossPct: 1);
      final e = _connected(thresholds: strict);
      expect(e.onMetrics(_m(loss: 1.2, rtt: 5)).quality, CallQuality.poor);
    });

    test('the worst single metric decides and the reason names it', () {
      final r = _connected().onMetrics(_m(loss: 0, rtt: 450, jitter: 5));
      expect(r.quality, CallQuality.poor);
      expect(r.reason, contains('round-trip'));
      expect(r.cause, QualityCause.network);
    });

    test('a sample with no usable numbers changes nothing', () {
      final e = _connected();
      final r = e.onMetrics(const CallMetrics(intervalValid: true));
      expect(r.quality, CallQuality.connecting);
    });

    test('a CPU-limited encoder is a device issue, not a network one', () {
      final r = _connected().onMetrics(_m(loss: 0, rtt: 5, limit: 'cpu'));
      expect(r.quality, CallQuality.good);
      expect(r.cause, QualityCause.device);
      expect(r.deviceLimited, isTrue);
    });

    test('a bandwidth-limited encoder is at least fair, network cause', () {
      final r = _connected().onMetrics(_m(loss: 0, rtt: 5, limit: 'bandwidth'));
      expect(r.quality, CallQuality.fair);
      expect(r.cause, QualityCause.network);
    });
  });

  group('hysteresis', () {
    test('the first measurement is adopted at once', () {
      final e = _connected();
      expect(e.quality, CallQuality.connecting);
      expect(e.onMetrics(_good).quality, CallQuality.good);
    });

    test('one or two bad samples do not change the state', () {
      final e = _connected();
      _feed(e, _good, 1);
      _feed(e, _poor, 2);
      expect(e.quality, CallQuality.good);
      e.onMetrics(_poor);
      expect(e.quality, CallQuality.poor);
    });

    test('a good sample in between restarts the worsening streak', () {
      final e = _connected();
      _feed(e, _good, 1);
      _feed(e, _poor, 2);
      _feed(e, _good, 1);
      _feed(e, _poor, 2);
      expect(e.quality, CallQuality.good);
    });

    test('a mixed bad streak moves only as far as its mildest sample', () {
      final e = _connected();
      _feed(e, _good, 1);
      e.onMetrics(_fair);
      e.onMetrics(_poor);
      e.onMetrics(_poor);
      expect(e.quality, CallQuality.fair);
    });

    test('recovery is slower than degradation', () {
      final e = _connected();
      _feed(e, _poor, 1);
      expect(e.quality, CallQuality.poor);
      _feed(e, _good, 4);
      expect(e.quality, CallQuality.poor);
      e.onMetrics(_good);
      expect(e.quality, CallQuality.good);
    });

    test('a bad sample interrupts recovery', () {
      final e = _connected();
      _feed(e, _poor, 1);
      _feed(e, _good, 4);
      e.onMetrics(_poor);
      _feed(e, _good, 4);
      expect(e.quality, CallQuality.poor);
    });

    test('mixed better samples recover only to the worst of them', () {
      final e = _connected();
      _feed(e, _poor, 1);
      _feed(e, _good, 3);
      _feed(e, _fair, 2);
      expect(e.quality, CallQuality.fair);
    });

    test('samples without data do not break a streak', () {
      final e = _connected();
      _feed(e, _good, 1);
      _feed(e, _poor, 2);
      e.onMetrics(const CallMetrics(intervalValid: true));
      e.onMetrics(_poor);
      expect(e.quality, CallQuality.poor);
    });

    test('the sample counts are configurable', () {
      final e = _connected(
        thresholds: const QualityThresholds(degradeAfterSamples: 1),
      );
      _feed(e, _good, 1);
      e.onMetrics(_poor);
      expect(e.quality, CallQuality.poor);
    });
  });

  group('connection state', () {
    test('starts as connecting and ignores metrics until connected', () {
      final e = QualityEvaluator();
      expect(e.quality, CallQuality.connecting);
      e.onMetrics(_good);
      expect(e.quality, CallQuality.connecting);
    });

    test('reconnecting and disconnected override measurements', () {
      final e = _connected();
      _feed(e, _good, 1);
      e.setLink(CallLinkState.reconnecting);
      expect(e.quality, CallQuality.reconnecting);
      e.onMetrics(_good);
      expect(e.quality, CallQuality.reconnecting);
      e.setLink(CallLinkState.disconnected);
      expect(e.quality, CallQuality.disconnected);
    });

    test('after reconnecting it shows connecting until a new measurement', () {
      final e = _connected();
      _feed(e, _good, 1);
      e.setLink(CallLinkState.reconnecting);
      e.setLink(CallLinkState.connected);
      expect(e.quality, CallQuality.connecting);
      e.onMetrics(_poor);
      expect(e.quality, CallQuality.poor);
    });

    test('reset returns to connecting', () {
      final e = _connected();
      _feed(e, _poor, 1);
      e.reset();
      expect(e.quality, CallQuality.connecting);
      e.onMetrics(_good);
      expect(e.quality, CallQuality.connecting);
    });
  });

  group('stalled media', () {
    test('three empty intervals in a row report a stall and show poor', () {
      final e = _connected();
      final stalled = _m(rtt: 5, stalled: true);
      _feed(e, _good, 1);
      _feed(e, stalled, 2);
      expect(e.report.stalled, isFalse);
      expect(e.quality, CallQuality.good);
      e.onMetrics(stalled);
      expect(e.report.stalled, isTrue);
      expect(e.quality, CallQuality.poor);
    });

    test('media flowing again clears the stall', () {
      final e = _connected();
      final stalled = _m(rtt: 5, stalled: true);
      _feed(e, stalled, 3);
      expect(e.report.stalled, isTrue);
      e.onMetrics(_good);
      expect(e.report.stalled, isFalse);
    });
  });

  group('outgoing-path scope', () {
    test('ignores incoming loss and jitter', () {
      final e = _connected(scope: QualityScope.outbound);
      _feed(e, _m(loss: 40, jitter: 500, rtt: 5, outLoss: 0), 6);
      expect(e.quality, CallQuality.good);
    });

    test('reacts to loss reported by the other phone, only after a streak', () {
      final e = _connected(scope: QualityScope.outbound);
      final bad = _m(rtt: 5, outLoss: 20);
      e.onMetrics(bad);
      e.onMetrics(bad);
      expect(e.quality, isNot(CallQuality.poor));
      e.onMetrics(bad);
      expect(e.quality, CallQuality.poor);
    });
  });
}

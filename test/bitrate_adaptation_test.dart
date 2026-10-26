// Adaptation decisions with fake quality reports. No peer connection is
// involved, so these tests do not show that a real encoder obeys the limits.
// ignore_for_file: avoid_relative_lib_imports
import 'package:flutter_test/flutter_test.dart';

import '../lib/features/video_call/models/bitrate_adaptation.dart';
import '../lib/features/video_call/models/call_quality.dart';

const QualityReport _poorNet = QualityReport(
  quality: CallQuality.poor,
  cause: QualityCause.network,
);
const QualityReport _poorDevice = QualityReport(
  quality: CallQuality.poor,
  cause: QualityCause.device,
);
const QualityReport _fair = QualityReport(
  quality: CallQuality.fair,
  cause: QualityCause.network,
);
const QualityReport _good = QualityReport(quality: CallQuality.good);

int _s(int seconds) => seconds * 1000;

void main() {
  test('starts at the normal limit and does nothing while good', () {
    final c = BitrateAdaptationController(const AdaptationConfig());
    expect(c.level, 0);
    expect(c.step, const VideoStep(maxBitrateKbps: 2500, maxFrameRate: 30));
    for (var i = 0; i < 20; i++) {
      expect(c.evaluate(_good, _s(i * 2)), isNull);
    }
    expect(c.level, 0);
  });

  test('a poor network path steps down once, then waits for the cooldown', () {
    final c = BitrateAdaptationController(const AdaptationConfig());
    final first = c.evaluate(_poorNet, _s(0));
    expect(first, const VideoStep(maxBitrateKbps: 1500, maxFrameRate: 30));
    expect(c.evaluate(_poorNet, _s(2)), isNull);
    expect(c.evaluate(_poorNet, _s(9)), isNull);
    final second = c.evaluate(_poorNet, _s(10));
    expect(second, const VideoStep(maxBitrateKbps: 900, maxFrameRate: 24));
    expect(c.level, 2);
  });

  test('never goes below the last step', () {
    final c = BitrateAdaptationController(const AdaptationConfig());
    for (var i = 0; i < 20; i++) {
      c.evaluate(_poorNet, _s(i * 10));
    }
    expect(c.level, 3);
    expect(c.step.maxBitrateKbps, 500);
    expect(c.evaluate(_poorNet, _s(500)), isNull);
  });

  test('a device (CPU) limit or a merely fair path never lowers the limit', () {
    final c = BitrateAdaptationController(const AdaptationConfig());
    for (var i = 0; i < 10; i++) {
      expect(c.evaluate(_poorDevice, _s(i * 10)), isNull);
      expect(c.evaluate(_fair, _s(i * 10 + 5)), isNull);
    }
    expect(c.level, 0);
  });

  test('reports that are not measurements are ignored', () {
    final c = BitrateAdaptationController(const AdaptationConfig());
    expect(c.evaluate(QualityReport.connecting, 0), isNull);
    expect(
      c.evaluate(const QualityReport(quality: CallQuality.reconnecting), 1),
      isNull,
    );
    expect(c.level, 0);
  });

  test('relaxing needs a run of good reports AND the longer cooldown', () {
    final c = BitrateAdaptationController(const AdaptationConfig());
    c.evaluate(_poorNet, _s(0));
    expect(c.level, 1);
    // Eight good reports, but only 16 s after the change: too early.
    for (var i = 1; i <= 8; i++) {
      expect(c.evaluate(_good, _s(i * 2)), isNull);
    }
    expect(c.level, 1);
    // The run is long enough and 30 s have passed: one step up.
    final up = c.evaluate(_good, _s(31));
    expect(up, const VideoStep(maxBitrateKbps: 2500, maxFrameRate: 30));
    expect(c.level, 0);
  });

  test('a non-good report restarts the run needed to relax', () {
    final c = BitrateAdaptationController(const AdaptationConfig());
    c.evaluate(_poorNet, _s(0));
    for (var i = 0; i < 7; i++) {
      c.evaluate(_good, _s(40 + i * 2));
    }
    c.evaluate(_fair, _s(60));
    expect(c.evaluate(_good, _s(62)), isNull);
    expect(c.level, 1);
  });

  test('relaxing goes up one step at a time', () {
    final c = BitrateAdaptationController(const AdaptationConfig());
    c.evaluate(_poorNet, _s(0));
    c.evaluate(_poorNet, _s(10));
    expect(c.level, 2);
    var t = 40;
    for (var i = 0; i < 8; i++) {
      c.evaluate(_good, _s(t));
      t += 2;
    }
    expect(c.level, 1);
    // Immediately after, another step is blocked by the cooldown.
    for (var i = 0; i < 8; i++) {
      expect(c.evaluate(_good, _s(t)), isNull);
      t += 2;
    }
    expect(c.level, 1);
  });

  test('flapping between poor and good cannot oscillate faster than the '
      'cooldowns', () {
    final c = BitrateAdaptationController(const AdaptationConfig());
    var changes = 0;
    for (var i = 0; i < 60; i++) {
      final report = i.isEven ? _poorNet : _good;
      if (c.evaluate(report, _s(i)) != null) changes++;
    }
    // The ladder has three down steps and each needs the 10 s cooldown; an
    // up step never happens because a run of 8 good reports never occurs.
    expect(changes, lessThanOrEqualTo(3));
    expect(c.level, greaterThan(0));
  });

  test('disabled configuration never changes anything', () {
    final c = BitrateAdaptationController(
      const AdaptationConfig(enabled: false),
    );
    expect(c.isActive, isFalse);
    expect(c.evaluate(_poorNet, 0), isNull);
  });

  test('disable() stops further changes and keeps the reason', () {
    final c = BitrateAdaptationController(const AdaptationConfig());
    c.disable('refused');
    expect(c.isActive, isFalse);
    expect(c.disabledReason, 'refused');
    expect(c.evaluate(_poorNet, 0), isNull);
  });

  test('applyFailed undoes the level change in either direction', () {
    final c = BitrateAdaptationController(const AdaptationConfig());
    c.evaluate(_poorNet, 0);
    expect(c.level, 1);
    c.applyFailed(wasDown: true);
    expect(c.level, 0);
    c.applyFailed(wasDown: false);
    expect(c.level, 1);
    c.applyFailed(wasDown: true);
    expect(c.level, 0);
  });

  test('reset returns to step 0 and re-enables', () {
    final c = BitrateAdaptationController(const AdaptationConfig());
    c.evaluate(_poorNet, 0);
    c.disable('x');
    c.reset();
    expect(c.level, 0);
    expect(c.isActive, isTrue);
    expect(c.disabledReason, isNull);
  });
}

// CallStatsService with FAKE raw statistics and a fake clock. This checks
// wiring, hysteresis, adaptation decisions and cleanup. It does not show
// that a real phone, encoder or Wi-Fi network behaves this way.
// ignore_for_file: avoid_relative_lib_imports
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import '../lib/features/video_call/models/bitrate_adaptation.dart';
import '../lib/features/video_call/models/call_quality.dart';
import '../lib/features/video_call/models/call_state.dart';
import '../lib/features/video_call/services/call_stats_service.dart';

List<RawStat> _stats({
  int txBytes = 0,
  int txPackets = 0,
  int remoteLost = 0,
  int rxBytes = 0,
  int rxPackets = 0,
  int rxLost = 0,
  double rttSeconds = 0.005,
}) {
  return <RawStat>[
    RawStat('outbound-rtp', <Object?, Object?>{
      'kind': 'video',
      'bytesSent': txBytes,
      'packetsSent': txPackets,
      'frameWidth': 1280,
      'frameHeight': 720,
      'framesPerSecond': 30,
    }),
    RawStat('remote-inbound-rtp', <Object?, Object?>{
      'kind': 'video',
      'packetsLost': remoteLost,
      'roundTripTime': rttSeconds,
    }),
    RawStat('inbound-rtp', <Object?, Object?>{
      'kind': 'video',
      'bytesReceived': rxBytes,
      'packetsReceived': rxPackets,
      'packetsLost': rxLost,
    }),
  ];
}

class _Harness {
  _Harness({
    bool applyResult = true,
    bool withApplier = true,
    AdaptationConfig adaptation = const AdaptationConfig(),
  }) {
    service = CallStatsService(
      adaptation: adaptation,
      clockMs: () => now,
      applyStep: withApplier
          ? (step) async {
              applied.add(step);
              return applyResult;
            }
          : null,
    );
    service.setLink(CallLinkState.connected);
  }

  late final CallStatsService service;
  int now = 0;
  final List<VideoStep> applied = <VideoStep>[];

  /// Feeds one sample [seconds] after the previous one. Lossy samples send
  /// 1000 packets per interval of which 200 are reported lost by the peer.
  Future<void> tick(int seconds, {required bool lossy}) async {
    now += seconds * 1000;
    final n = now ~/ 1000;
    service.ingest(
      _stats(
        txBytes: n * 125000,
        txPackets: n * 500,
        remoteLost: lossy ? n * 100 : 0,
        rxBytes: n * 125000,
        rxPackets: n * 500,
      ),
    );
    await pumpEventQueue();
  }
}

void main() {
  test('turns two samples into rates and a quality state', () async {
    final h = _Harness();
    addTearDown(h.service.dispose);
    h.service.ingest(_stats());
    h.now = 2000;
    h.service.ingest(
      _stats(txBytes: 250000, txPackets: 300, rxBytes: 125000, rxPackets: 200),
    );
    final d = h.service.diagnostics.value;
    expect(d.samples, 2);
    expect(d.metrics.txVideoKbps, closeTo(1000, 1e-9));
    expect(d.metrics.rxVideoKbps, closeTo(500, 1e-9));
    expect(d.metrics.txWidth, 1280);
    expect(d.metrics.rttMs, closeTo(5, 1e-9));
    expect(d.report.quality, CallQuality.good);
    expect(h.service.quality.value, CallQuality.good);
    expect(d.step, const VideoStep(maxBitrateKbps: 2500, maxFrameRate: 30));
  });

  test('an empty report shows only unavailable values', () {
    final h = _Harness();
    addTearDown(h.service.dispose);
    h.service.ingest(const <RawStat>[]);
    h.now = 2000;
    h.service.ingest(const <RawStat>[]);
    final m = h.service.diagnostics.value.metrics;
    expect(m.txVideoKbps, isNull);
    expect(m.rttMs, isNull);
    expect(m.txWidth, isNull);
    expect(h.service.quality.value, CallQuality.connecting);
  });

  test('the quality notifier only fires when the shown state changes', () {
    final h = _Harness();
    addTearDown(h.service.dispose);
    var changes = 0;
    h.service.quality.addListener(() => changes++);
    h.service.ingest(_stats());
    h.now = 2000;
    h.service.ingest(_stats(txBytes: 1000, txPackets: 10));
    h.now = 4000;
    h.service.ingest(_stats(txBytes: 2000, txPackets: 20));
    // connecting -> good once; further good samples do not notify.
    expect(changes, 1);
  });

  group('adaptation', () {
    test('lowers the send limit after sustained poor outgoing path', () async {
      final h = _Harness();
      addTearDown(h.service.dispose);
      await h.tick(0, lossy: false); // baseline
      await h.tick(2, lossy: true);
      await h.tick(2, lossy: true);
      expect(h.applied, isEmpty, reason: 'two samples are not enough');
      await h.tick(2, lossy: true);
      expect(h.applied, <VideoStep>[
        const VideoStep(maxBitrateKbps: 1500, maxFrameRate: 30),
      ]);
      expect(h.service.stepLevel, 1);
      expect(h.service.quality.value, CallQuality.poor);
      expect(h.service.diagnostics.value.adaptationNote, contains('Lowered'));
    });

    test('keeps a cooldown between two reductions', () async {
      final h = _Harness();
      addTearDown(h.service.dispose);
      await h.tick(0, lossy: false);
      for (var i = 0; i < 3; i++) {
        await h.tick(2, lossy: true);
      }
      expect(h.applied, hasLength(1));
      // 2, 4, 6, 8 s later: still inside the 10 s cooldown.
      for (var i = 0; i < 4; i++) {
        await h.tick(2, lossy: true);
      }
      expect(h.applied, hasLength(1));
      await h.tick(2, lossy: true);
      expect(h.applied, hasLength(2));
      expect(h.service.stepLevel, 2);
    });

    test('good samples alone never change the limit', () async {
      final h = _Harness();
      addTearDown(h.service.dispose);
      for (var i = 0; i < 20; i++) {
        await h.tick(2, lossy: false);
      }
      expect(h.applied, isEmpty);
      expect(h.service.stepLevel, 0);
    });

    test(
      'a refused change is undone and adaptation switches off after two',
      () async {
        final h = _Harness(applyResult: false);
        addTearDown(h.service.dispose);
        await h.tick(0, lossy: false);
        for (var i = 0; i < 3; i++) {
          await h.tick(2, lossy: true);
        }
        expect(h.applied, hasLength(1));
        expect(h.service.stepLevel, 0, reason: 'the refused step was undone');
        expect(h.service.diagnostics.value.adaptationActive, isTrue);

        for (var i = 0; i < 5; i++) {
          await h.tick(2, lossy: true);
        }
        expect(h.applied, hasLength(2));
        expect(h.service.diagnostics.value.adaptationActive, isFalse);
        expect(h.service.diagnostics.value.adaptationNote, contains('refused'));

        for (var i = 0; i < 10; i++) {
          await h.tick(2, lossy: true);
        }
        expect(h.applied, hasLength(2), reason: 'no more attempts');
      },
    );

    test('without an applier adaptation is reported as unavailable', () async {
      final h = _Harness(withApplier: false);
      addTearDown(h.service.dispose);
      await h.tick(0, lossy: false);
      for (var i = 0; i < 3; i++) {
        await h.tick(2, lossy: true);
      }
      final d = h.service.diagnostics.value;
      expect(d.adaptationActive, isFalse);
      expect(d.adaptationNote, isNotNull);
      expect(h.service.stepLevel, 0);
    });

    test('disabled configuration only measures', () async {
      final h = _Harness(adaptation: const AdaptationConfig(enabled: false));
      addTearDown(h.service.dispose);
      await h.tick(0, lossy: false);
      for (var i = 0; i < 6; i++) {
        await h.tick(2, lossy: true);
      }
      expect(h.applied, isEmpty);
      expect(h.service.quality.value, CallQuality.poor);
    });
  });

  group('connection events and lifecycle', () {
    test('reconnecting is shown and the baseline is dropped', () async {
      final h = _Harness();
      addTearDown(h.service.dispose);
      await h.tick(0, lossy: false);
      await h.tick(2, lossy: false);
      expect(h.service.quality.value, CallQuality.good);

      h.service.setLink(CallLinkState.reconnecting);
      expect(h.service.quality.value, CallQuality.reconnecting);
      h.service.setLink(CallLinkState.connected);
      expect(h.service.quality.value, CallQuality.connecting);

      await h.tick(2, lossy: false);
      final m = h.service.diagnostics.value.metrics;
      expect(m.intervalValid, isFalse);
      expect(m.txVideoKbps, isNull);
    });

    test(
      'pausing the app drops the baseline so no rate spans the pause',
      () async {
        final h = _Harness();
        addTearDown(h.service.dispose);
        await h.tick(0, lossy: false);
        await h.tick(2, lossy: false);
        expect(h.service.diagnostics.value.metrics.txVideoKbps, isNotNull);
        h.service.onAppPaused();
        await h.tick(2, lossy: false);
        expect(h.service.diagnostics.value.metrics.txVideoKbps, isNull);
      },
    );

    test('reset forgets the previous call', () async {
      final h = _Harness();
      addTearDown(h.service.dispose);
      await h.tick(0, lossy: false);
      for (var i = 0; i < 3; i++) {
        await h.tick(2, lossy: true);
      }
      expect(h.service.stepLevel, 1);
      h.service.reset();
      expect(h.service.stepLevel, 0);
      expect(h.service.samples, 0);
      expect(h.service.quality.value, CallQuality.connecting);
      expect(h.service.diagnostics.value.samples, 0);
      expect(h.service.diagnostics.value.metrics.txVideoKbps, isNull);
    });

    test(
      'everything is safe after dispose, and dispose can be repeated',
      () async {
        final gate = Completer<bool>();
        final applied = <VideoStep>[];
        var now = 0;
        final service = CallStatsService(
          clockMs: () => now,
          applyStep: (step) {
            applied.add(step);
            return gate.future;
          },
        );
        service.setLink(CallLinkState.connected);
        service.ingest(_stats());
        for (var i = 1; i <= 3; i++) {
          now = i * 2000;
          service.ingest(
            _stats(
              txBytes: i * 250000,
              txPackets: i * 1000,
              remoteLost: i * 200,
            ),
          );
        }
        await pumpEventQueue();
        expect(applied, hasLength(1), reason: 'a change is still in flight');

        service.dispose();
        service.dispose();
        gate.complete(true);
        await pumpEventQueue();
        service.ingest(_stats());
        service.setLink(CallLinkState.disconnected);
        service.onAppPaused();
        service.reset();
      },
    );
  });
}

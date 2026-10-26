import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/bitrate_adaptation.dart';
import '../models/call_quality.dart';
import '../models/call_state.dart' show RawStat;
import '../models/call_stats.dart';

/// Applies a sender limit. Returns false when the platform refused.
typedef VideoStepApplier = Future<bool> Function(VideoStep step);

/// Everything the diagnostics panel shows. Immutable.
class CallDiagnostics {
  const CallDiagnostics({
    this.metrics = CallMetrics.unavailable,
    this.report = QualityReport.connecting,
    this.link = CallLinkState.connecting,
    this.step,
    this.stepLevel = 0,
    this.stepCount = 1,
    this.adaptationActive = false,
    this.adaptationNote,
    this.samples = 0,
  });

  static const CallDiagnostics initial = CallDiagnostics();

  final CallMetrics metrics;
  final QualityReport report;
  final CallLinkState link;

  /// The sender limit currently requested (null before the first call).
  final VideoStep? step;
  final int stepLevel;
  final int stepCount;
  final bool adaptationActive;

  /// Why adaptation is off or what it last did, in plain words.
  final String? adaptationNote;

  /// Number of statistics samples received in this call.
  final int samples;
}

/// Lightweight call diagnostics.
///
/// It does not poll anything itself: the peer link's single [StatsPoller]
/// delivers raw statistics to [ingest]. This service turns them into
/// metrics, a stable quality state and (optionally) a conservative sender
/// limit. Nothing here runs when no call is up.
class CallStatsService {
  CallStatsService({
    CallStatsParser parser = const CallStatsParser(),
    QualityThresholds thresholds = const QualityThresholds(),
    AdaptationConfig adaptation = const AdaptationConfig(),
    this.applyStep,
    int Function()? clockMs,
  }) : _parser = parser,
       _tracker = CallStatsTracker(),
       _overall = QualityEvaluator(thresholds: thresholds),
       _outbound = QualityEvaluator(
         thresholds: thresholds,
         scope: QualityScope.outbound,
       ),
       _controller = BitrateAdaptationController(adaptation) {
    if (clockMs != null) {
      _clockMs = clockMs;
    } else {
      final watch = Stopwatch()..start();
      _clockMs = () => watch.elapsedMilliseconds;
    }
  }

  /// Applies a sender limit. When null, adaptation is reported as off.
  VideoStepApplier? applyStep;

  final CallStatsParser _parser;
  final CallStatsTracker _tracker;
  final QualityEvaluator _overall;
  final QualityEvaluator _outbound;
  final BitrateAdaptationController _controller;
  late final int Function() _clockMs;

  /// Full diagnostics, updated once per sample. Only the open diagnostics
  /// panel listens to this.
  final ValueNotifier<CallDiagnostics> diagnostics =
      ValueNotifier<CallDiagnostics>(CallDiagnostics.initial);

  /// Only changes when the shown quality state changes.
  final ValueNotifier<CallQuality> quality = ValueNotifier<CallQuality>(
    CallQuality.connecting,
  );

  CallLinkState _link = CallLinkState.connecting;
  int _samples = 0;
  int _generation = 0;
  bool _applying = false;
  int _applyFailures = 0;
  String? _note;
  bool _disposed = false;

  CallLinkState get link => _link;
  int get samples => _samples;
  int get stepLevel => _controller.level;
  VideoStep get currentStep => _controller.step;

  /// A connection event from the call controller.
  void setLink(CallLinkState link) {
    if (_disposed || link == _link) return;
    _link = link;
    _overall.setLink(link);
    _outbound.setLink(link);
    if (link != CallLinkState.connected) {
      // Counters are not comparable across an outage.
      _tracker.reset();
    }
    _publish(_lastMetrics);
  }

  CallMetrics _lastMetrics = CallMetrics.unavailable;

  /// One reading from the peer link.
  void ingest(List<RawStat> stats) {
    if (_disposed) return;
    final now = _clockMs();
    final CallStatsSample sample;
    try {
      sample = _parser.parse(stats, timestampMs: now);
    } catch (error) {
      debugPrint('Parsing statistics failed: ${error.runtimeType}');
      return;
    }
    final metrics = _tracker.add(sample);
    _lastMetrics = metrics;
    _samples++;

    _overall.onMetrics(metrics);
    final outbound = _outbound.onMetrics(metrics);

    if (!_applying && _link == CallLinkState.connected) {
      final before = _controller.level;
      final next = _controller.evaluate(outbound, now);
      if (next != null) {
        unawaited(_apply(next, wasDown: _controller.level > before));
      }
    }
    _publish(metrics);
  }

  /// The app went to the background: the next sample must not be compared
  /// with one taken before the pause.
  void onAppPaused() {
    if (_disposed) return;
    _tracker.reset();
  }

  /// New call (or call ended): forget everything measured so far.
  void reset() {
    if (_disposed) return;
    _generation++;
    _tracker.reset();
    _overall.reset();
    _outbound.reset();
    _controller.reset();
    _link = CallLinkState.connecting;
    _samples = 0;
    _applying = false;
    _applyFailures = 0;
    _note = null;
    _lastMetrics = CallMetrics.unavailable;
    _publish(CallMetrics.unavailable);
  }

  Future<void> _apply(VideoStep step, {required bool wasDown}) async {
    final applier = applyStep;
    if (applier == null) {
      _controller.applyFailed(wasDown: wasDown);
      _controller.disable('Not supported here.');
      _note = 'Automatic bitrate limits are not available.';
      _publish(_lastMetrics);
      return;
    }
    final generation = _generation;
    _applying = true;
    var ok = false;
    try {
      ok = await applier(step);
    } catch (error) {
      debugPrint('Applying a video limit failed: ${error.runtimeType}');
    }
    if (_disposed || generation != _generation) return;
    _applying = false;
    if (ok) {
      _applyFailures = 0;
      _note = wasDown
          ? 'Lowered the send limit to $step because the path was poor.'
          : 'Raised the send limit to $step after stable good quality.';
    } else {
      _controller.applyFailed(wasDown: wasDown);
      _applyFailures++;
      if (_applyFailures >= 2) {
        _controller.disable('The platform refused the sender settings.');
        _note = 'Automatic limits switched off: the platform refused them.';
      } else {
        _note = 'The platform refused a sender limit change.';
      }
    }
    _publish(_lastMetrics);
  }

  void _publish(CallMetrics metrics) {
    if (_disposed) return;
    final report = _overall.report;
    quality.value = report.quality;
    diagnostics.value = CallDiagnostics(
      metrics: metrics,
      report: report,
      link: _link,
      step: _controller.step,
      stepLevel: _controller.level,
      stepCount: _controller.stepCount,
      adaptationActive: _controller.isActive,
      adaptationNote: _note ?? _controller.disabledReason,
      samples: _samples,
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    diagnostics.dispose();
    quality.dispose();
  }
}

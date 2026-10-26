import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/call_state.dart' show RawStat;

/// Calls [read] on a fixed interval and hands the result to [onStats].
///
/// * Only one read is in flight at a time: if a read is slower than the
///   interval, the next tick is skipped instead of piling up.
/// * [stop] cancels the timer and discards the result of any read that is
///   still running, so nothing is delivered after a call ended.
/// * [start] and [stop] are idempotent.
class StatsPoller {
  StatsPoller({
    required this.interval,
    required this.read,
    required this.onStats,
    this.onError,
  });

  final Duration interval;
  final Future<List<RawStat>> Function() read;
  final void Function(List<RawStat> stats) onStats;
  final void Function(Object error)? onError;

  Timer? _timer;
  bool _busy = false;
  int _generation = 0;

  bool get isRunning => _timer != null;
  bool get isBusy => _busy;

  /// Starts the periodic timer. With [immediate] the first read happens
  /// right away instead of after one interval.
  void start({bool immediate = true}) {
    if (_timer != null) return;
    _timer = Timer.periodic(interval, (_) => unawaited(_tick()));
    if (immediate) unawaited(_tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _generation++;
  }

  Future<void> _tick() async {
    if (_busy || _timer == null) return;
    _busy = true;
    final generation = _generation;
    try {
      final stats = await read();
      if (generation != _generation || _timer == null) return;
      onStats(stats);
    } catch (error) {
      if (generation == _generation) {
        debugPrint('Reading statistics failed: ${error.runtimeType}');
        onError?.call(error);
      }
    } finally {
      _busy = false;
    }
  }
}

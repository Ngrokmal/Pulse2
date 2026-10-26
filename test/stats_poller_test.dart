// StatsPoller lifecycle tests with a fake reader and real (short) timers.
// ignore_for_file: avoid_relative_lib_imports
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import '../lib/features/video_call/models/call_state.dart';
import '../lib/features/video_call/services/stats_poller.dart';

const Duration _tick = Duration(milliseconds: 20);

void main() {
  test(
    'reads immediately, then on every interval, and stops on stop()',
    () async {
      var reads = 0;
      final poller = StatsPoller(
        interval: _tick,
        read: () async {
          reads++;
          return const <RawStat>[];
        },
        onStats: (_) {},
      );
      poller.start();
      expect(poller.isRunning, isTrue);
      expect(reads, 1, reason: 'the first read happens right away');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      poller.stop();
      expect(poller.isRunning, isFalse);
      expect(reads, greaterThanOrEqualTo(3));

      final afterStop = reads;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(reads, afterStop, reason: 'no reads after stop');
    },
  );

  test('without immediate the first read waits one interval', () async {
    var reads = 0;
    final poller = StatsPoller(
      interval: const Duration(milliseconds: 60),
      read: () async {
        reads++;
        return const <RawStat>[];
      },
      onStats: (_) {},
    );
    addTearDown(poller.stop);
    poller.start(immediate: false);
    expect(reads, 0);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(reads, greaterThanOrEqualTo(1));
  });

  test('start twice keeps a single timer', () async {
    var reads = 0;
    final poller = StatsPoller(
      interval: const Duration(milliseconds: 500),
      read: () async {
        reads++;
        return const <RawStat>[];
      },
      onStats: (_) {},
    );
    addTearDown(poller.stop);
    poller.start();
    poller.start();
    expect(reads, 1);
  });

  test('a slow read is never overlapped by the next tick', () async {
    var running = 0;
    var maxRunning = 0;
    var reads = 0;
    final poller = StatsPoller(
      interval: const Duration(milliseconds: 10),
      read: () async {
        reads++;
        running++;
        if (running > maxRunning) maxRunning = running;
        await Future<void>.delayed(const Duration(milliseconds: 55));
        running--;
        return const <RawStat>[];
      },
      onStats: (_) {},
    );
    poller.start();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    poller.stop();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(maxRunning, 1);
    expect(reads, lessThan(8), reason: 'ticks during a read are skipped');
  });

  test('a result that arrives after stop() is discarded', () async {
    final gate = Completer<List<RawStat>>();
    var delivered = 0;
    final poller = StatsPoller(
      interval: _tick,
      read: () => gate.future,
      onStats: (_) => delivered++,
    );
    poller.start();
    expect(poller.isBusy, isTrue);
    poller.stop();
    gate.complete(const <RawStat>[]);
    await pumpEventQueue();
    expect(delivered, 0);
    expect(poller.isBusy, isFalse);
  });

  test('a failing read is reported and polling continues', () async {
    var reads = 0;
    final errors = <Object>[];
    var delivered = 0;
    final poller = StatsPoller(
      interval: _tick,
      read: () async {
        reads++;
        if (reads == 1) throw StateError('boom');
        return const <RawStat>[];
      },
      onStats: (_) => delivered++,
      onError: errors.add,
    );
    addTearDown(poller.stop);
    poller.start();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(errors, hasLength(1));
    expect(delivered, greaterThanOrEqualTo(1));
    expect(poller.isRunning, isTrue);
  });

  test('stop is idempotent and the poller can be started again', () async {
    var reads = 0;
    final poller = StatsPoller(
      interval: const Duration(milliseconds: 500),
      read: () async {
        reads++;
        return const <RawStat>[];
      },
      onStats: (_) {},
    );
    poller.stop();
    poller.stop();
    poller.start();
    await pumpEventQueue();
    poller.stop();
    poller.stop();
    expect(reads, 1);
    poller.start();
    await pumpEventQueue();
    poller.stop();
    expect(reads, 2);
    expect(poller.isRunning, isFalse);
  });
}

import 'call_stats.dart';

/// What the small quality indicator shows.
enum CallQuality {
  connecting,
  good,
  fair,
  poor,
  reconnecting,
  disconnected;

  String get label {
    switch (this) {
      case CallQuality.connecting:
        return 'Connecting';
      case CallQuality.good:
        return 'Good';
      case CallQuality.fair:
        return 'Fair';
      case CallQuality.poor:
        return 'Poor';
      case CallQuality.reconnecting:
        return 'Reconnecting';
      case CallQuality.disconnected:
        return 'Disconnected';
    }
  }

  /// True for the three states that come from measurements.
  bool get isMeasured =>
      this == CallQuality.good ||
      this == CallQuality.fair ||
      this == CallQuality.poor;
}

/// What the call controller knows about the link, from connection events.
enum CallLinkState { connecting, reconnecting, connected, disconnected }

/// Why quality is limited, as far as the statistics can tell.
enum QualityCause {
  /// Nothing limiting was detected.
  none,

  /// Loss, round-trip time, jitter, bandwidth limitation or a media stall.
  network,

  /// The encoder reports it is limited by CPU (device performance).
  device,
}

/// Thresholds for grading one sampling interval.
///
/// These are engineering starting points for a short-range Wi-Fi call, NOT
/// validated universal values. They are plain constructor parameters so they
/// can be tuned after measuring on real phones.
class QualityThresholds {
  const QualityThresholds({
    this.fairLossPct = 2,
    this.poorLossPct = 8,
    this.fairRttMs = 150,
    this.poorRttMs = 400,
    this.fairJitterMs = 30,
    this.poorJitterMs = 100,
    this.degradeAfterSamples = 3,
    this.improveAfterSamples = 5,
    this.stallAfterSamples = 3,
  });

  final double fairLossPct;
  final double poorLossPct;
  final double fairRttMs;
  final double poorRttMs;
  final double fairJitterMs;
  final double poorJitterMs;

  /// Consecutive worse samples needed before the shown state gets worse.
  final int degradeAfterSamples;

  /// Consecutive better samples needed before the shown state gets better.
  /// Larger than [degradeAfterSamples] on purpose: recover slowly.
  final int improveAfterSamples;

  /// Consecutive valid intervals without any received media byte before a
  /// stall is reported.
  final int stallAfterSamples;
}

enum QualityScope {
  /// Everything the statistics offer: both directions, RTT and jitter.
  overall,

  /// Only evidence about this phone's OUTGOING video: loss reported by the
  /// other phone, round-trip time and the encoder's limitation reason.
  /// Used to decide whether lowering the send bitrate can help.
  outbound,
}

/// Result of an evaluation.
class QualityReport {
  const QualityReport({
    required this.quality,
    this.cause = QualityCause.none,
    this.reason,
    this.stalled = false,
    this.deviceLimited = false,
  });

  static const QualityReport connecting = QualityReport(
    quality: CallQuality.connecting,
  );

  final CallQuality quality;
  final QualityCause cause;

  /// Short human-readable explanation, or null when there is nothing to say.
  final String? reason;

  /// No media bytes arrived for several intervals although ICE is up.
  final bool stalled;

  /// The encoder reports a CPU limitation (independent of the network grade).
  final bool deviceLimited;
}

enum _Grade { good, fair, poor }

int _severity(CallQuality quality) {
  switch (quality) {
    case CallQuality.good:
      return 0;
    case CallQuality.fair:
      return 1;
    case CallQuality.poor:
      return 2;
    case CallQuality.connecting:
    case CallQuality.reconnecting:
    case CallQuality.disconnected:
      return -1;
  }
}

CallQuality _qualityOf(int severity) {
  switch (severity) {
    case 0:
      return CallQuality.good;
    case 1:
      return CallQuality.fair;
    default:
      return CallQuality.poor;
  }
}

/// Turns per-interval metrics into a stable quality state.
///
/// * One sample never changes the shown state: getting worse needs
///   [QualityThresholds.degradeAfterSamples] consecutive worse samples,
///   getting better needs [QualityThresholds.improveAfterSamples] better ones.
/// * When a streak ends in a change, the new state is the MILDEST of the
///   worse samples (or the WORST of the better samples), so a noisy streak
///   never jumps further than every sample in it justifies.
/// * Samples with no usable numbers are ignored (they neither count for nor
///   against a state).
/// * Connection events override everything: connecting, reconnecting and
///   disconnected are shown as such regardless of old measurements.
class QualityEvaluator {
  QualityEvaluator({
    this.thresholds = const QualityThresholds(),
    this.scope = QualityScope.overall,
  });

  final QualityThresholds thresholds;
  final QualityScope scope;

  CallQuality _state = CallQuality.connecting;
  CallLinkState _link = CallLinkState.connecting;
  QualityCause _cause = QualityCause.none;
  String? _reason;
  bool _stalled = false;
  bool _deviceLimited = false;

  int _worseStreak = 0;
  int _worseLevel = 99;
  int _betterStreak = 0;
  int _betterLevel = -1;
  int _stallStreak = 0;

  CallQuality get quality => _state;

  QualityReport get report => QualityReport(
    quality: _state,
    cause: _cause,
    reason: _reason,
    stalled: _stalled,
    deviceLimited: _deviceLimited,
  );

  /// Applies a connection event.
  void setLink(CallLinkState link) {
    if (link == _link) return;
    _link = link;
    _clearStreaks();
    _stallStreak = 0;
    _stalled = false;
    _cause = QualityCause.none;
    _reason = null;
    _deviceLimited = false;
    switch (link) {
      case CallLinkState.connecting:
      case CallLinkState.connected:
        // Neutral until the first measurement arrives.
        _state = CallQuality.connecting;
      case CallLinkState.reconnecting:
        _state = CallQuality.reconnecting;
      case CallLinkState.disconnected:
        _state = CallQuality.disconnected;
    }
  }

  /// Back to the initial state (new call).
  void reset() {
    _link = CallLinkState.connecting;
    _state = CallQuality.connecting;
    _clearStreaks();
    _stallStreak = 0;
    _stalled = false;
    _cause = QualityCause.none;
    _reason = null;
    _deviceLimited = false;
  }

  /// Feeds one interval. Ignored unless the link is [CallLinkState.connected].
  QualityReport onMetrics(CallMetrics metrics) {
    if (_link != CallLinkState.connected) return report;

    // Stall detection.
    if (metrics.intervalValid) {
      if (metrics.rxStalled) {
        _stallStreak++;
      } else if (metrics.rxBytesDelta != null) {
        _stallStreak = 0;
      }
    }
    _stalled = _stallStreak >= thresholds.stallAfterSamples;
    _deviceLimited = metrics.qualityLimitation == 'cpu';

    final sample = _grade(metrics);
    if (sample == null) return report;

    final target = _severity(sample.quality);
    _cause = sample.cause;
    _reason = sample.reason;

    if (!_state.isMeasured) {
      if (scope == QualityScope.overall) {
        // First measurement after connecting/reconnecting: adopt it, so the
        // indicator does not stay on "Connecting" while data is flowing.
        _state = sample.quality;
        _clearStreaks();
        return report;
      }
      // The outgoing-path evaluator drives bitrate changes, so even its first
      // measurement must prove itself over a streak: start from "good".
      _state = CallQuality.good;
    }

    // A confirmed stall is already several intervals of evidence: show it
    // without waiting for another streak.
    if (_stalled &&
        scope == QualityScope.overall &&
        _state != CallQuality.poor) {
      _state = CallQuality.poor;
      _clearStreaks();
      return report;
    }

    final current = _severity(_state);
    if (target > current) {
      _betterStreak = 0;
      _betterLevel = -1;
      _worseStreak++;
      if (target < _worseLevel) _worseLevel = target;
      if (_worseStreak >= thresholds.degradeAfterSamples) {
        _state = _qualityOf(_worseLevel);
        _clearStreaks();
      }
    } else if (target < current) {
      _worseStreak = 0;
      _worseLevel = 99;
      _betterStreak++;
      if (target > _betterLevel) _betterLevel = target;
      if (_betterStreak >= thresholds.improveAfterSamples) {
        _state = _qualityOf(_betterLevel);
        _clearStreaks();
      }
    } else {
      _clearStreaks();
    }
    return report;
  }

  void _clearStreaks() {
    _worseStreak = 0;
    _worseLevel = 99;
    _betterStreak = 0;
    _betterLevel = -1;
  }

  /// Grades one interval; null when it carries no usable evidence.
  ({CallQuality quality, QualityCause cause, String? reason})? _grade(
    CallMetrics m,
  ) {
    final t = thresholds;
    final inbound = scope == QualityScope.overall;

    final double? loss = inbound
        ? _worst(m.worstRxLossPct, m.outboundLossPct)
        : m.outboundLossPct;
    final double? rtt = m.rttMs;
    final double? jitter = inbound ? m.jitterMs : null;
    final bandwidthLimited = m.qualityLimitation == 'bandwidth';

    final stalledEvidence = _stalled && inbound;
    final hasEvidence =
        loss != null ||
        rtt != null ||
        jitter != null ||
        stalledEvidence ||
        bandwidthLimited;
    if (!hasEvidence) return null;

    var grade = _Grade.good;
    String? reason;

    void raise(_Grade level, String text) {
      if (level.index > grade.index) {
        grade = level;
        reason = text;
      }
    }

    if (loss != null) {
      if (loss >= t.poorLossPct) {
        raise(_Grade.poor, 'High packet loss (${loss.toStringAsFixed(1)}%)');
      } else if (loss >= t.fairLossPct) {
        raise(_Grade.fair, 'Some packet loss (${loss.toStringAsFixed(1)}%)');
      }
    }
    if (rtt != null) {
      if (rtt >= t.poorRttMs) {
        raise(_Grade.poor, 'High round-trip time (${rtt.round()} ms)');
      } else if (rtt >= t.fairRttMs) {
        raise(_Grade.fair, 'Raised round-trip time (${rtt.round()} ms)');
      }
    }
    if (jitter != null) {
      if (jitter >= t.poorJitterMs) {
        raise(_Grade.poor, 'High jitter (${jitter.round()} ms)');
      } else if (jitter >= t.fairJitterMs) {
        raise(_Grade.fair, 'Raised jitter (${jitter.round()} ms)');
      }
    }
    if (bandwidthLimited) {
      raise(_Grade.fair, 'The encoder is limited by available bandwidth');
    }
    if (stalledEvidence) {
      raise(_Grade.poor, 'No media received for several seconds');
    }

    QualityCause cause = QualityCause.none;
    if (grade != _Grade.good) {
      cause = QualityCause.network;
    } else if (m.qualityLimitation == 'cpu') {
      cause = QualityCause.device;
      reason = 'The encoder is limited by this phone\u2019s CPU';
    }
    final CallQuality quality;
    switch (grade) {
      case _Grade.good:
        quality = CallQuality.good;
      case _Grade.fair:
        quality = CallQuality.fair;
      case _Grade.poor:
        quality = CallQuality.poor;
    }
    return (quality: quality, cause: cause, reason: reason);
  }

  static double? _worst(double? a, double? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a > b ? a : b;
  }
}

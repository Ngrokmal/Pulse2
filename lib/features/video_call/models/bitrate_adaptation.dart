import 'call_quality.dart';

/// One level of the sender limits: a cap on the video bitrate and on the
/// frame rate. Resolution is NOT part of a step: the installed
/// flutter_webrtc API gives no verified way to change it on a running
/// camera stream.
class VideoStep {
  const VideoStep({required this.maxBitrateKbps, required this.maxFrameRate});

  final int maxBitrateKbps;
  final int maxFrameRate;

  @override
  bool operator ==(Object other) =>
      other is VideoStep &&
      other.maxBitrateKbps == maxBitrateKbps &&
      other.maxFrameRate == maxFrameRate;

  @override
  int get hashCode => Object.hash(maxBitrateKbps, maxFrameRate);

  @override
  String toString() => '$maxBitrateKbps kbit/s @ $maxFrameRate fps';
}

/// Settings of the conservative bitrate adaptation.
///
/// libwebrtc already runs its own congestion control. This layer only adds
/// a lower CAP when the outgoing path has been poor for a while, and lifts
/// the cap again slowly. Step 0 is the normal limit (2500 kbit/s, 30 fps,
/// the same values Phase 3 used).
class AdaptationConfig {
  const AdaptationConfig({
    this.enabled = true,
    this.steps = const <VideoStep>[
      VideoStep(maxBitrateKbps: 2500, maxFrameRate: 30),
      VideoStep(maxBitrateKbps: 1500, maxFrameRate: 30),
      VideoStep(maxBitrateKbps: 900, maxFrameRate: 24),
      VideoStep(maxBitrateKbps: 500, maxFrameRate: 15),
    ],
    this.downCooldown = const Duration(seconds: 10),
    this.upCooldown = const Duration(seconds: 30),
    this.goodSamplesBeforeUp = 8,
  });

  final bool enabled;

  /// From best (index 0) to most restrictive.
  final List<VideoStep> steps;

  /// Minimum time between two changes when getting more restrictive.
  final Duration downCooldown;

  /// Minimum time between two changes when relaxing the cap.
  final Duration upCooldown;

  /// Consecutive "good" evaluations needed before relaxing one step.
  final int goodSamplesBeforeUp;
}

/// Decides when to move one step down or up. Pure logic: it never touches
/// the peer connection. The caller applies the returned step and tells the
/// controller whether that worked.
///
/// Rules:
/// * Only a `poor` outgoing-path report that is caused by the network moves
///   down; a CPU limit, `fair` or `good` never does.
/// * Never more than one step per cooldown, in either direction.
/// * Moving up needs a run of consecutive `good` reports AND the longer
///   up-cooldown, so quality returns gradually.
/// * Any non-good report resets the run needed for moving up.
class BitrateAdaptationController {
  BitrateAdaptationController(this.config);

  final AdaptationConfig config;

  int _level = 0;
  int _goodRun = 0;
  int? _lastChangeMs;
  bool _disabled = false;
  String? _disabledReason;

  /// Current step index (0 = no extra restriction).
  int get level => _level;
  VideoStep get step => config.steps[_level];
  bool get isActive => config.enabled && !_disabled && config.steps.length > 1;
  String? get disabledReason => _disabledReason;
  int get stepCount => config.steps.length;

  /// Stops all further changes for this call (for example when the platform
  /// refused the sender parameters).
  void disable(String reason) {
    _disabled = true;
    _disabledReason = reason;
  }

  /// New call: back to step 0.
  void reset() {
    _level = 0;
    _goodRun = 0;
    _lastChangeMs = null;
    _disabled = false;
    _disabledReason = null;
  }

  /// Returns the step to apply, or null for "leave things as they are".
  /// [nowMs] must be monotonic.
  VideoStep? evaluate(QualityReport report, int nowMs) {
    if (!isActive) return null;

    final quality = report.quality;
    if (!quality.isMeasured) {
      _goodRun = 0;
      return null;
    }

    final last = _lastChangeMs;
    final sinceMs = last == null ? null : nowMs - last;

    if (quality == CallQuality.poor && report.cause == QualityCause.network) {
      _goodRun = 0;
      if (_level >= config.steps.length - 1) return null;
      if (sinceMs != null && sinceMs < config.downCooldown.inMilliseconds) {
        return null;
      }
      _level++;
      _lastChangeMs = nowMs;
      return config.steps[_level];
    }

    if (quality == CallQuality.good) {
      _goodRun++;
      if (_level == 0) return null;
      if (_goodRun < config.goodSamplesBeforeUp) return null;
      if (sinceMs != null && sinceMs < config.upCooldown.inMilliseconds) {
        return null;
      }
      _level--;
      _lastChangeMs = nowMs;
      _goodRun = 0;
      return config.steps[_level];
    }

    // Fair, or poor because of the device: hold.
    _goodRun = 0;
    return null;
  }

  /// The caller could not apply the step returned by [evaluate]: undo it so
  /// the controller's idea of the current level stays truthful.
  void applyFailed({required bool wasDown}) {
    if (wasDown) {
      if (_level > 0) _level--;
    } else {
      if (_level < config.steps.length - 1) _level++;
    }
  }
}

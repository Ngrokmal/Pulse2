import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../models/bitrate_adaptation.dart';
import '../models/call_quality.dart';
import '../models/call_state.dart';
import '../models/signal_message.dart';
import 'call_negotiator.dart';
import 'call_stats_service.dart';
import 'call_wakelock.dart';
import 'flutter_webrtc_peer_link.dart';
import 'local_media_service.dart';
import 'local_signal_service.dart';

/// What the call screen talks to.
///
/// Glue between the existing services:
/// * [LocalSignalService] carries the negotiation messages (it is never
///   stopped from here: ending a call does not stop the Host).
/// * [LocalMediaService] owns the camera and microphone (opened once).
/// * [CallNegotiator] decides what happens when; [FlutterWebRtcPeerLink]
///   talks to the native WebRTC stack.
class WebRtcService extends ChangeNotifier {
  WebRtcService({
    required LocalSignalService signal,
    required LocalMediaService media,
    required NegotiationRole role,
    CallVideoSettings videoSettings = const CallVideoSettings(),
  }) : _signal = signal,
       _media = media,
       _videoSettings = videoSettings,
       stats = CallStatsService() {
    stats.applyStep = _applyVideoStep;
    _negotiator = CallNegotiator(
      role: role,
      linkFactory: _createLink,
      send: _signal.sendCall,
    )..addListener(_onNegotiatorChanged);
    _callSub = _signal.callMessages.listen(_onSignalMessage);
    _signal.addListener(_onSignalChanged);
    _signalWasConnected = _signal.isConnected;
  }

  final LocalSignalService _signal;
  final LocalMediaService _media;
  final CallVideoSettings _videoSettings;
  late final CallNegotiator _negotiator;
  StreamSubscription<SignalMessage>? _callSub;

  /// Diagnostics, quality state and bitrate adaptation for the current call.
  /// Owned (and disposed) by this service.
  final CallStatsService stats;

  final CallWakelock _wakelock = CallWakelock();

  /// Shows the remote video. Owned (and disposed) by this service.
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();

  /// Call length, updated once per second while a call is up.
  final ValueNotifier<Duration> callDuration = ValueNotifier<Duration>(
    Duration.zero,
  );

  FlutterWebRtcPeerLink? _link;
  bool _rendererReady = false;
  Future<void>? _rendererInit;
  bool _signalWasConnected = false;
  bool _disposed = false;
  bool _speakerOn = true;
  bool _speakerBusy = false;
  bool _speakerSynced = false;
  bool _starting = false;
  String? _startProblem;
  Timer? _durationTimer;
  DateTime? _connectedAt;

  CallPhase get phase => _negotiator.phase;
  CallMilestones get milestones => _negotiator.milestones;
  MediaSnapshot get snapshot => _negotiator.snapshot;
  bool get isCallActive => _negotiator.isActive;
  bool get speakerOn => _speakerOn;
  bool get signalingConnected => _signal.isConnected;

  /// Start/accept is possible when signaling is up and no call is running.
  bool get canStartCall =>
      _signal.isConnected && _negotiator.canStart && !_starting;
  bool get hasIncomingCall => _negotiator.phase == CallPhase.incoming;

  /// A user-facing problem that stopped the call from even starting
  /// (permissions, camera), or the negotiator's own failure text.
  String get statusText => _startProblem ?? _negotiator.statusText;
  String? get warning => _negotiator.warning;
  bool get hasFailed =>
      _startProblem != null || _negotiator.phase == CallPhase.failed;

  /// Candidate counts for diagnostics (no addresses are exposed).
  String get candidateSummary =>
      '${_negotiator.localCandidateCount} local / '
      '${_negotiator.remoteCandidateCount} remote candidates';

  Future<void> startCall() async {
    // Rapid repeated taps (Start, Accept) must not run the start sequence
    // twice at the same time.
    if (_disposed || _starting) return;
    _starting = true;
    notifyListeners();
    try {
      await _startCall();
    } finally {
      _starting = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _startCall() async {
    if (_disposed) return;
    if (!_signal.isConnected) {
      _startProblem = 'Connect to the other phone first.';
      notifyListeners();
      return;
    }
    if (!_negotiator.canStart) return;
    _startProblem = null;
    notifyListeners();

    try {
      await _ensureRenderer();
      await _media.start();
    } catch (error) {
      debugPrint('Preparing the call failed: ${error.runtimeType}');
    }
    if (_disposed) return;
    if (!_rendererReady) {
      _startProblem = 'The video display could not be started.';
      notifyListeners();
      return;
    }
    if (!_media.isReady) {
      _startProblem =
          _media.message ??
          'The camera and microphone are not ready, so the call cannot '
              'start.';
      notifyListeners();
      return;
    }
    if (!_signal.isConnected) {
      _startProblem = 'The connection to the other phone was lost.';
      notifyListeners();
      return;
    }
    await _negotiator.startCall();
  }

  /// Ends the call, or declines an incoming one. The Host keeps running.
  Future<void> hangUp() async {
    _startProblem = null;
    await _negotiator.hangUp();
  }

  Future<void> toggleSpeaker() async {
    final link = _link;
    if (link == null || _speakerBusy) return;
    _speakerBusy = true;
    try {
      final next = !_speakerOn;
      if (await link.setSpeaker(next)) {
        if (_disposed) return;
        _speakerOn = next;
        notifyListeners();
      }
    } finally {
      _speakerBusy = false;
    }
  }

  /// The app went to the background. The call is not touched; only the
  /// statistics timer is paused so nothing polls while the screen is off.
  void onAppPaused() {
    if (_disposed) return;
    _link?.pauseStats();
    stats.onAppPaused();
  }

  /// The app is visible again: statistics resume with a fresh baseline.
  void onAppResumed() {
    if (_disposed) return;
    _link?.resumeStats();
  }

  // ----------------------------------------------------------- internals --

  PeerLink _createLink() {
    final stream = _media.stream;
    if (stream == null) {
      throw StateError('The local camera stream is not available.');
    }
    final link = FlutterWebRtcPeerLink(
      localStream: stream,
      remoteRenderer: remoteRenderer,
      settings: _videoSettings,
    );
    stats.reset();
    link.onRawStats = stats.ingest;
    _link = link;
    _speakerOn = true;
    _speakerSynced = false;
    return link;
  }

  Future<bool> _applyVideoStep(VideoStep step) async {
    final link = _link;
    if (link == null) return false;
    return link.applyVideoLimits(step);
  }

  CallLinkState _linkStateFor(CallPhase phase) {
    if (!phase.isActive) return CallLinkState.disconnected;
    if (_negotiator.isReconnecting) return CallLinkState.reconnecting;
    if (phase == CallPhase.connected || phase == CallPhase.mediaFlowing) {
      return CallLinkState.connected;
    }
    return CallLinkState.connecting;
  }

  Future<void> _ensureRenderer() {
    if (_rendererReady) return Future<void>.value();
    return _rendererInit ??= remoteRenderer.initialize().then((_) {
      _rendererReady = true;
    });
  }

  void _onSignalMessage(SignalMessage message) {
    if (_disposed) return;
    unawaited(_negotiator.onSignal(message));
  }

  void _onSignalChanged() {
    if (_disposed) return;
    final connected = _signal.isConnected;
    if (_signalWasConnected && !connected) {
      unawaited(_negotiator.onSignalingLost());
    }
    _signalWasConnected = connected;
    notifyListeners();
  }

  void _onNegotiatorChanged() {
    if (_disposed) return;
    final phase = _negotiator.phase;
    if (phase == CallPhase.connected || phase == CallPhase.mediaFlowing) {
      _startDurationTimer();
    } else if (!phase.isActive) {
      _stopDurationTimer();
      _link = null;
    }
    // Once the local side is ready, show the audio route that was really
    // selected instead of assuming the loudspeaker.
    final link = _link;
    if (!_speakerSynced && link != null && phase == CallPhase.waitingForPeer) {
      _speakerSynced = true;
      _speakerOn = link.speakerRouted;
    }
    stats.setLink(_linkStateFor(phase));
    // Keep the screen on only while the call is really connected.
    unawaited(
      _wakelock.set(
        phase == CallPhase.connected || phase == CallPhase.mediaFlowing,
      ),
    );
    notifyListeners();
  }

  void _startDurationTimer() {
    if (_durationTimer != null) return;
    _connectedAt = DateTime.now();
    callDuration.value = Duration.zero;
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final since = _connectedAt;
      if (since != null) callDuration.value = DateTime.now().difference(since);
    });
  }

  void _stopDurationTimer() {
    _durationTimer?.cancel();
    _durationTimer = null;
    _connectedAt = null;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_wakelock.set(false));
    _signal.removeListener(_onSignalChanged);
    unawaited(_callSub?.cancel());
    _callSub = null;
    _stopDurationTimer();
    _negotiator.removeListener(_onNegotiatorChanged);
    unawaited(_shutdown());
    super.dispose();
  }

  Future<void> _shutdown() async {
    // Close the peer connection before the renderer it feeds is disposed.
    await _negotiator.shutdown();
    _negotiator.dispose();
    try {
      await _rendererInit;
    } catch (_) {
      // Initialization failed; nothing to dispose then.
    }
    if (_rendererReady) {
      try {
        await remoteRenderer.dispose();
      } catch (error) {
        debugPrint(
          'Disposing the remote renderer failed: '
          '${error.runtimeType}',
        );
      }
    }
    callDuration.dispose();
    stats.dispose();
  }
}

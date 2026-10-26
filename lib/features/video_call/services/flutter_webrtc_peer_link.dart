import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../models/bitrate_adaptation.dart';
import '../models/call_signal.dart';
import '../models/call_state.dart';
import 'call_negotiator.dart';
import 'stats_poller.dart';

/// Offline ICE configuration: no STUN, no TURN. Only candidates gathered on
/// this phone's own network interfaces (the hotspot LAN) are used.
const Map<String, dynamic> kOfflineIceConfiguration = <String, dynamic>{
  'iceServers': <Map<String, dynamic>>[],
  'sdpSemantics': 'unified-plan',
};

/// Tuning values for the outgoing video. Capture resolution and frame rate
/// are set in `LocalMediaService`; these only limit what is sent.
class CallVideoSettings {
  const CallVideoSettings({this.maxBitrateKbps = 2500, this.maxFrameRate = 30});

  /// Upper limit for the video encoder, in kilobits per second.
  final int maxBitrateKbps;
  final int maxFrameRate;

  /// The same limits as a [VideoStep] (step 0 of the adaptation ladder).
  VideoStep get asStep =>
      VideoStep(maxBitrateKbps: maxBitrateKbps, maxFrameRate: maxFrameRate);
}

/// [PeerLink] backed by a real `RTCPeerConnection` from flutter_webrtc.
///
/// It does not own the local camera/microphone stream (that belongs to
/// `LocalMediaService`) and never stops those tracks. It owns the peer
/// connection, remote stream assembly and the statistics timer.
class FlutterWebRtcPeerLink implements PeerLink {
  FlutterWebRtcPeerLink({
    required this.localStream,
    required this.remoteRenderer,
    this.settings = const CallVideoSettings(),
    this.statsInterval = const Duration(seconds: 2),
  });

  final MediaStream localStream;
  final RTCVideoRenderer remoteRenderer;
  final CallVideoSettings settings;
  final Duration statsInterval;

  @override
  void Function(IceCandidatePayload candidate)? onLocalCandidate;
  @override
  void Function(LinkConnectionState state)? onConnectionState;
  @override
  void Function()? onRemoteTrack;
  @override
  void Function(MediaSnapshot snapshot)? onMediaSnapshot;

  /// Raw statistics, once per [statsInterval], for the diagnostics service.
  /// Not part of [PeerLink]: only the real link has statistics.
  void Function(List<RawStat> stats)? onRawStats;

  RTCPeerConnection? _pc;
  RTCRtpSender? _videoSender;
  MediaStream? _syntheticRemoteStream;
  StatsPoller? _poller;
  bool _statsWanted = false;
  bool _speakerRouted = false;
  bool _closed = false;
  bool _senderLimitsApplied = false;
  bool _videoAttached = false;

  @override
  Future<void> open() async {
    final tracks = localStream.getTracks();
    if (tracks.isEmpty) {
      throw StateError('The local stream has no tracks.');
    }
    final pc = await createPeerConnection(kOfflineIceConfiguration);
    if (_closed) {
      await pc.close();
      await pc.dispose();
      return;
    }
    _pc = pc;

    pc.onIceCandidate = _handleLocalCandidate;
    pc.onTrack = _handleTrack;
    pc.onIceConnectionState = _handleIceState;
    pc.onConnectionState = _handlePeerState;
    pc.onIceGatheringState = (state) {
      debugPrint('ICE gathering: $state');
    };
    pc.onSignalingState = (state) {
      debugPrint('Signaling state: $state');
    };

    // Same tracks as the local preview: the camera is opened only once.
    for (final track in tracks) {
      final sender = await pc.addTrack(track, localStream);
      if (track.kind == 'video') _videoSender = sender;
    }

    // Video calls should come out of the loudspeaker, not the earpiece.
    _speakerRouted = await setSpeaker(true);
  }

  /// True when the loudspeaker was successfully selected when the call
  /// opened. False means the platform refused and the audio route is
  /// whatever Android chose.
  bool get speakerRouted => _speakerRouted;

  @override
  Future<String> createOffer() async {
    final pc = _requirePc();
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    return _sdpOf(offer);
  }

  @override
  Future<void> acceptOffer(String sdp) async {
    final pc = _requirePc();
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
  }

  @override
  Future<String> createAnswer() async {
    final pc = _requirePc();
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    return _sdpOf(answer);
  }

  @override
  Future<void> acceptAnswer(String sdp) async {
    final pc = _requirePc();
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
  }

  @override
  Future<void> addRemoteCandidate(IceCandidatePayload candidate) async {
    final pc = _requirePc();
    await pc.addCandidate(
      RTCIceCandidate(
        candidate.candidate,
        candidate.sdpMid,
        candidate.sdpMLineIndex,
      ),
    );
  }

  /// Routes audio to the loudspeaker (true) or the earpiece (false).
  /// Returns false when the platform refused.
  Future<bool> setSpeaker(bool on) async {
    try {
      await Helper.setSpeakerphoneOn(on);
      return true;
    } catch (error) {
      debugPrint('Setting the speakerphone failed: ${error.runtimeType}');
      return false;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _statsWanted = false;
    _poller?.stop();
    _poller = null;
    onRawStats = null;

    final pc = _pc;
    _pc = null;
    _videoSender = null;
    if (pc != null) {
      pc.onIceCandidate = null;
      pc.onTrack = null;
      pc.onIceConnectionState = null;
      pc.onConnectionState = null;
      pc.onIceGatheringState = null;
      pc.onSignalingState = null;
    }

    try {
      remoteRenderer.srcObject = null;
    } catch (error) {
      debugPrint('Clearing the remote renderer failed: ${error.runtimeType}');
    }
    final synthetic = _syntheticRemoteStream;
    _syntheticRemoteStream = null;
    if (synthetic != null) {
      try {
        await synthetic.dispose();
      } catch (error) {
        debugPrint('Disposing remote stream failed: ${error.runtimeType}');
      }
    }

    if (pc != null) {
      try {
        await pc.close();
      } catch (error) {
        debugPrint('Closing the peer connection failed: ${error.runtimeType}');
      }
      try {
        await pc.dispose();
      } catch (error) {
        debugPrint(
          'Disposing the peer connection failed: '
          '${error.runtimeType}',
        );
      }
    }
  }

  // -------------------------------------------------------------- events --

  void _handleLocalCandidate(RTCIceCandidate candidate) {
    final line = candidate.candidate;
    if (_closed || line == null || line.isEmpty) return;
    onLocalCandidate?.call(
      IceCandidatePayload(
        candidate: line,
        sdpMid: candidate.sdpMid,
        sdpMLineIndex: candidate.sdpMLineIndex,
      ),
    );
  }

  Future<void> _handleTrack(RTCTrackEvent event) async {
    if (_closed) return;
    final isVideo = event.track.kind == 'video';
    try {
      if (event.streams.isNotEmpty) {
        final stream = event.streams.first;
        // Attach on the first stream, and once more when the video track
        // arrives so the renderer picks the video track up.
        if (remoteRenderer.srcObject?.id != stream.id ||
            (isVideo && !_videoAttached)) {
          remoteRenderer.srcObject = stream;
        }
      } else {
        // Some versions deliver tracks without a stream: assemble one.
        var stream = _syntheticRemoteStream;
        stream ??= await createLocalMediaStream('remote');
        if (_closed) {
          await stream.dispose();
          return;
        }
        _syntheticRemoteStream = stream;
        await stream.addTrack(event.track);
        remoteRenderer.srcObject = stream;
      }
      if (isVideo) _videoAttached = true;
    } catch (error) {
      debugPrint('Attaching a remote track failed: ${error.runtimeType}');
    }
    onRemoteTrack?.call();
  }

  void _handleIceState(RTCIceConnectionState state) {
    debugPrint('ICE connection: $state');
    switch (state) {
      case RTCIceConnectionState.RTCIceConnectionStateChecking:
        _report(LinkConnectionState.checking);
      case RTCIceConnectionState.RTCIceConnectionStateConnected:
      case RTCIceConnectionState.RTCIceConnectionStateCompleted:
        _onConnected();
      case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
        _report(LinkConnectionState.disconnected);
      case RTCIceConnectionState.RTCIceConnectionStateFailed:
        _report(LinkConnectionState.failed);
      case RTCIceConnectionState.RTCIceConnectionStateClosed:
        _report(LinkConnectionState.closed);
      default:
        break;
    }
  }

  void _handlePeerState(RTCPeerConnectionState state) {
    debugPrint('Peer connection: $state');
    switch (state) {
      case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
        _report(LinkConnectionState.checking);
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        _onConnected();
      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        _report(LinkConnectionState.disconnected);
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        _report(LinkConnectionState.failed);
      case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
        _report(LinkConnectionState.closed);
      default:
        break;
    }
  }

  void _report(LinkConnectionState state) {
    if (_closed) return;
    onConnectionState?.call(state);
  }

  void _onConnected() {
    if (_closed) return;
    onConnectionState?.call(LinkConnectionState.connected);
    if (!_senderLimitsApplied) {
      _senderLimitsApplied = true;
      unawaited(applyVideoLimits(settings.asStep));
    }
    _statsWanted = true;
    _ensurePoller().start();
  }

  StatsPoller _ensurePoller() {
    return _poller ??= StatsPoller(
      interval: statsInterval,
      read: _readStats,
      onStats: _handleStats,
    );
  }

  /// Stops the statistics timer while the app is in the background. The
  /// call itself is not touched.
  void pauseStats() {
    _poller?.stop();
  }

  /// Restarts the statistics timer after [pauseStats], if the call had
  /// reached the connected state before.
  void resumeStats() {
    if (_closed || !_statsWanted) return;
    _ensurePoller().start();
  }

  /// Caps bitrate and frame rate of the outgoing video through
  /// `RTCRtpSender.setParameters`. Returns false when there is no video
  /// sender or the platform refused; the encoder then keeps its previous
  /// limits. This changes only the encoder's CAP: it does not set a start
  /// bitrate and does not change the capture resolution.
  Future<bool> applyVideoLimits(VideoStep step) async {
    final sender = _videoSender;
    if (sender == null || _closed) return false;
    try {
      final parameters = sender.parameters;
      final encodings = parameters.encodings;
      final bitrate = step.maxBitrateKbps * 1000;
      if (encodings == null || encodings.isEmpty) {
        parameters.encodings = <RTCRtpEncoding>[
          RTCRtpEncoding(maxBitrate: bitrate, maxFramerate: step.maxFrameRate),
        ];
      } else {
        for (final encoding in encodings) {
          encoding.maxBitrate = bitrate;
          encoding.maxFramerate = step.maxFrameRate;
        }
      }
      final applied = await sender.setParameters(parameters);
      debugPrint('Video sender limits ($step) applied: $applied');
      return applied;
    } catch (error) {
      debugPrint('Video sender limits not applied: ${error.runtimeType}');
      return false;
    }
  }

  Future<List<RawStat>> _readStats() async {
    final pc = _pc;
    if (pc == null || _closed) return const <RawStat>[];
    final reports = await pc.getStats();
    return reports
        .map((report) => RawStat(report.type, report.values, id: report.id))
        .toList(growable: false);
  }

  void _handleStats(List<RawStat> stats) {
    if (_closed) return;
    onMediaSnapshot?.call(MediaSnapshot.fromStats(stats));
    onRawStats?.call(stats);
  }

  RTCPeerConnection _requirePc() {
    final pc = _pc;
    if (pc == null || _closed) {
      throw StateError('The peer connection is not open.');
    }
    return pc;
  }

  String _sdpOf(RTCSessionDescription description) {
    final sdp = description.sdp;
    if (sdp == null || sdp.isEmpty) {
      throw StateError('The session description is empty.');
    }
    return sdp;
  }
}

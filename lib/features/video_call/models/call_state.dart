import '../services/local_signal_service.dart' show SignalRole;
import 'call_signal.dart';

/// Who creates the SDP offer. Exactly one phone is the offerer, which avoids
/// both phones offering at the same time (glare).
enum NegotiationRole { offerer, answerer }

/// The Host phone offers; the phone that joined answers.
NegotiationRole negotiationRoleFor(SignalRole role) => role == SignalRole.host
    ? NegotiationRole.offerer
    : NegotiationRole.answerer;

/// Where a call is. Only real events move it forward: for example
/// [connected] needs an ICE/peer connection event, not just a WebSocket.
enum CallPhase {
  idle,

  /// The other phone is ready and waits for this phone to accept.
  incoming,

  /// Opening the peer connection and adding local tracks.
  preparing,

  /// Local side ready, `call_ready` sent, waiting for the other phone.
  waitingForPeer,

  /// Offer/answer exchange in progress.
  negotiating,

  /// SDP exchanged; ICE is looking for a working network path.
  connecting,

  /// ICE/peer connection established. Media may not be flowing yet.
  connected,

  /// Remote video frames are actually being decoded.
  mediaFlowing,
  ended,
  failed;

  bool get isTerminal => this == ended || this == failed;

  /// True while a call occupies the peer connection.
  bool get isActive =>
      this == preparing ||
      this == waitingForPeer ||
      this == negotiating ||
      this == connecting ||
      this == connected ||
      this == mediaFlowing;

  /// Allowed moves. Any active phase may also end or fail.
  bool canMoveTo(CallPhase next) {
    if (next == this) return true;
    switch (this) {
      case CallPhase.idle:
        return next == incoming || next == preparing;
      case CallPhase.incoming:
        return next == preparing || next == ended || next == idle;
      case CallPhase.preparing:
        return next == waitingForPeer || next == ended || next == failed;
      case CallPhase.waitingForPeer:
        return next == negotiating || next == ended || next == failed;
      case CallPhase.negotiating:
        return next == connecting ||
            next == connected ||
            next == ended ||
            next == failed;
      case CallPhase.connecting:
        return next == connected || next == ended || next == failed;
      case CallPhase.connected:
        return next == mediaFlowing ||
            next == connecting ||
            next == ended ||
            next == failed;
      case CallPhase.mediaFlowing:
        return next == connected ||
            next == connecting ||
            next == ended ||
            next == failed;
      case CallPhase.ended:
      case CallPhase.failed:
        return next == idle || next == incoming || next == preparing;
    }
  }
}

/// Simplified connection state reported by a peer link.
enum LinkConnectionState { checking, connected, disconnected, failed, closed }

/// Separate milestones shown to the user. Each one needs its own evidence.
class CallMilestones {
  const CallMilestones({
    this.negotiated = false,
    this.iceConnected = false,
    this.remoteTrack = false,
    this.remoteVideoFrames = false,
    this.remoteAudioFlowing = false,
  });

  /// Offer and answer were exchanged and installed.
  final bool negotiated;

  /// ICE / peer connection reported connected.
  final bool iceConnected;

  /// An `onTrack` event arrived.
  final bool remoteTrack;

  /// Statistics show remote video frames decoded.
  final bool remoteVideoFrames;

  /// Statistics show remote audio bytes received.
  final bool remoteAudioFlowing;

  CallMilestones copyWith({
    bool? negotiated,
    bool? iceConnected,
    bool? remoteTrack,
    bool? remoteVideoFrames,
    bool? remoteAudioFlowing,
  }) {
    return CallMilestones(
      negotiated: negotiated ?? this.negotiated,
      iceConnected: iceConnected ?? this.iceConnected,
      remoteTrack: remoteTrack ?? this.remoteTrack,
      remoteVideoFrames: remoteVideoFrames ?? this.remoteVideoFrames,
      remoteAudioFlowing: remoteAudioFlowing ?? this.remoteAudioFlowing,
    );
  }
}

/// Holds remote ICE candidates until the remote description is installed.
class PendingCandidateQueue {
  PendingCandidateQueue({this.maxQueued = 128});

  final int maxQueued;
  final List<IceCandidatePayload> _items = <IceCandidatePayload>[];
  bool _open = false;

  int get length => _items.length;

  /// True once the remote description is installed.
  bool get isOpen => _open;

  /// Returns true when [candidate] may be applied now. Otherwise it is queued
  /// and false is returned.
  bool submit(IceCandidatePayload candidate) {
    if (_open) return true;
    if (_items.length >= maxQueued) {
      throw const CallSignalException(
        CallErrorCode.invalidCandidate,
        'Too many candidates arrived before the session description.',
      );
    }
    _items.add(candidate);
    return false;
  }

  /// Marks the remote description as installed and returns the queued
  /// candidates in arrival order.
  List<IceCandidatePayload> open() {
    _open = true;
    final drained = List<IceCandidatePayload>.of(_items);
    _items.clear();
    return drained;
  }

  void reset() {
    _open = false;
    _items.clear();
  }
}

/// A reading of the media statistics of the peer connection.
class MediaSnapshot {
  const MediaSnapshot({
    this.receivedVideoFrames = 0,
    this.receivedAudioBytes = 0,
    this.receivedWidth,
    this.receivedHeight,
    this.receivedFps,
    this.sentVideoBytes = 0,
    this.sentAudioBytes = 0,
    this.sentWidth,
    this.sentHeight,
    this.sentFps,
  });

  static const MediaSnapshot empty = MediaSnapshot();

  final int receivedVideoFrames;
  final int receivedAudioBytes;
  final int? receivedWidth;
  final int? receivedHeight;
  final double? receivedFps;
  final int sentVideoBytes;
  final int sentAudioBytes;
  final int? sentWidth;
  final int? sentHeight;
  final double? sentFps;

  /// Builds a snapshot from raw `getStats` entries (type + values).
  factory MediaSnapshot.fromStats(Iterable<RawStat> stats) {
    var rxFrames = 0;
    var rxAudio = 0;
    int? rxW;
    int? rxH;
    double? rxFps;
    var txVideo = 0;
    var txAudio = 0;
    int? txW;
    int? txH;
    double? txFps;

    for (final stat in stats) {
      final kind = _kindOf(stat.values);
      final isInbound = stat.type == 'inbound-rtp';
      final isOutbound = stat.type == 'outbound-rtp';
      if (!isInbound && !isOutbound) continue;
      if (kind == 'video') {
        if (isInbound) {
          rxFrames += _int(stat.values['framesDecoded']) ?? 0;
          rxW = _int(stat.values['frameWidth']) ?? rxW;
          rxH = _int(stat.values['frameHeight']) ?? rxH;
          rxFps = _double(stat.values['framesPerSecond']) ?? rxFps;
        } else {
          txVideo += _int(stat.values['bytesSent']) ?? 0;
          txW = _int(stat.values['frameWidth']) ?? txW;
          txH = _int(stat.values['frameHeight']) ?? txH;
          txFps = _double(stat.values['framesPerSecond']) ?? txFps;
        }
      } else if (kind == 'audio') {
        if (isInbound) {
          rxAudio += _int(stat.values['bytesReceived']) ?? 0;
        } else {
          txAudio += _int(stat.values['bytesSent']) ?? 0;
        }
      }
    }
    return MediaSnapshot(
      receivedVideoFrames: rxFrames,
      receivedAudioBytes: rxAudio,
      receivedWidth: rxW,
      receivedHeight: rxH,
      receivedFps: rxFps,
      sentVideoBytes: txVideo,
      sentAudioBytes: txAudio,
      sentWidth: txW,
      sentHeight: txH,
      sentFps: txFps,
    );
  }

  static String? _kindOf(Map<Object?, Object?> values) {
    final kind = values['kind'] ?? values['mediaType'];
    return kind is String ? kind : null;
  }

  static int? _int(Object? value) {
    if (value == null) return null;
    if (value is num) return value.toInt();
    return num.tryParse(value.toString())?.toInt();
  }

  static double? _double(Object? value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return num.tryParse(value.toString())?.toDouble();
  }

  /// Short text for the status panel. Contains no addresses.
  String describe() {
    String size(int? w, int? h) =>
        (w == null || h == null || w == 0) ? '?' : '${w}x$h';
    String fps(double? value) =>
        value == null ? '' : ' @ ${value.toStringAsFixed(0)} fps';
    final rx = receivedVideoFrames > 0
        ? 'Receiving ${size(receivedWidth, receivedHeight)}${fps(receivedFps)}'
        : 'No remote video frames yet';
    final tx = sentVideoBytes > 0
        ? 'Sending ${size(sentWidth, sentHeight)}${fps(sentFps)}'
        : 'Not sending video yet';
    return '$rx\n$tx';
  }

  @override
  bool operator ==(Object other) =>
      other is MediaSnapshot &&
      other.receivedVideoFrames == receivedVideoFrames &&
      other.receivedAudioBytes == receivedAudioBytes &&
      other.receivedWidth == receivedWidth &&
      other.receivedHeight == receivedHeight &&
      other.sentVideoBytes == sentVideoBytes &&
      other.sentAudioBytes == sentAudioBytes &&
      other.sentWidth == sentWidth &&
      other.sentHeight == sentHeight;

  @override
  int get hashCode => Object.hash(
    receivedVideoFrames,
    receivedAudioBytes,
    receivedWidth,
    receivedHeight,
    sentVideoBytes,
    sentAudioBytes,
    sentWidth,
    sentHeight,
  );
}

/// One entry of `RTCPeerConnection.getStats()`, without the plugin type.
class RawStat {
  const RawStat(this.type, this.values, {this.id});

  final String type;
  final Map<Object?, Object?> values;

  /// The report id, used to link entries (candidate pair -> candidate,
  /// RTP stream -> codec). Null when the source did not provide one.
  final String? id;
}

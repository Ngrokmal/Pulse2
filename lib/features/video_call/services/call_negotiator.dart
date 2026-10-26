import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/call_signal.dart';
import '../models/call_state.dart';
import '../models/signal_message.dart';

/// Sends one call message to the other phone.
typedef CallSignalSender =
    CallSendResult Function(SignalType type, Map<String, Object?> payload);

/// The native side of a call: one peer connection with local tracks.
///
/// [CallNegotiator] drives it. The real implementation uses flutter_webrtc;
/// unit tests use a fake, because native WebRTC does not run in Dart tests.
abstract class PeerLink {
  /// Called for every local ICE candidate that gets gathered.
  void Function(IceCandidatePayload candidate)? onLocalCandidate;

  /// Called when ICE / the peer connection changes state.
  void Function(LinkConnectionState state)? onConnectionState;

  /// Called when a remote track arrives (`onTrack`).
  void Function()? onRemoteTrack;

  /// Called with fresh media statistics while the call is up.
  void Function(MediaSnapshot snapshot)? onMediaSnapshot;

  /// Creates the peer connection and adds the local tracks.
  Future<void> open();

  /// Creates an offer, installs it as local description, returns its SDP.
  Future<String> createOffer();

  /// Installs the remote offer.
  Future<void> acceptOffer(String sdp);

  /// Creates an answer, installs it as local description, returns its SDP.
  Future<String> createAnswer();

  /// Installs the remote answer.
  Future<void> acceptAnswer(String sdp);

  Future<void> addRemoteCandidate(IceCandidatePayload candidate);

  /// Releases the peer connection and remote media. Must be safe to call
  /// more than once. Does not stop the local camera or microphone.
  Future<void> close();
}

/// Deterministic call negotiation on top of the Phase 2 signaling channel.
///
/// * The Host is the offerer, the joining phone is the answerer.
/// * Each phone sends `call_ready` once its local media and peer connection
///   exist. The offerer only creates its offer after it is ready itself AND
///   has received the other phone's `call_ready`.
/// * Incoming messages are handled one at a time, in order.
/// * Local ICE candidates are held back until the SDP they belong to has been
///   sent, so the other phone never sees a candidate before its offer/answer.
/// * Remote candidates that still arrive early are queued and applied after
///   the remote description is installed.
class CallNegotiator extends ChangeNotifier {
  CallNegotiator({
    required this.role,
    required PeerLink Function() linkFactory,
    required CallSignalSender send,
    this.connectTimeout = const Duration(seconds: 30),
    this.disconnectGrace = const Duration(seconds: 8),
  }) : _linkFactory = linkFactory,
       _send = send;

  final NegotiationRole role;
  final Duration connectTimeout;
  final Duration disconnectGrace;
  final PeerLink Function() _linkFactory;
  final CallSignalSender _send;

  PeerLink? _link;
  CallPhase _phase = CallPhase.idle;
  CallMilestones _milestones = const CallMilestones();
  MediaSnapshot _snapshot = MediaSnapshot.empty;
  String? _failure;
  String? _endReason;
  String? _warning;
  bool _disposed = false;

  // Incremented for every new call so late async work can be ignored.
  int _generation = 0;
  Future<void> _tail = Future<void>.value();

  bool _localReady = false;
  bool _remoteReady = false;
  bool _offerSent = false;
  bool _offerReceived = false;
  bool _answerReceived = false;
  bool _localCandidatesReleased = false;
  final List<IceCandidatePayload> _heldLocalCandidates =
      <IceCandidatePayload>[];
  final PendingCandidateQueue _remoteCandidates = PendingCandidateQueue();

  int _localCandidateCount = 0;
  int _remoteCandidateCount = 0;
  Timer? _connectTimer;
  Timer? _graceTimer;

  CallPhase get phase => _phase;
  CallMilestones get milestones => _milestones;
  MediaSnapshot get snapshot => _snapshot;

  /// Why the call failed, when [phase] is [CallPhase.failed].
  String? get failure => _failure;

  /// Why the call ended, when [phase] is [CallPhase.ended].
  String? get endReason => _endReason;

  /// Non-fatal problem, e.g. the other phone sent an unexpected message.
  String? get warning => _warning;

  bool get isActive => _phase.isActive;
  bool get canStart =>
      _phase == CallPhase.idle ||
      _phase == CallPhase.incoming ||
      _phase.isTerminal;

  /// True while ICE reported a disconnect during a call and the grace
  /// period before giving up is running. libwebrtc may still recover on its
  /// own; the call is failed when the grace period ends.
  bool get isReconnecting =>
      _phase == CallPhase.connecting && (_graceTimer?.isActive ?? false);
  int get localCandidateCount => _localCandidateCount;
  int get remoteCandidateCount => _remoteCandidateCount;

  String get statusText {
    switch (_phase) {
      case CallPhase.idle:
        return 'No call yet.';
      case CallPhase.incoming:
        return 'The other phone is ready. Start the call to join it.';
      case CallPhase.preparing:
        return 'Starting camera, microphone and connection\u2026';
      case CallPhase.waitingForPeer:
        return 'Waiting for the other phone to be ready\u2026';
      case CallPhase.negotiating:
        return 'Negotiating media\u2026';
      case CallPhase.connecting:
        return 'Looking for a network path between the phones (ICE)\u2026';
      case CallPhase.connected:
        return _milestones.remoteTrack
            ? 'Connected. Waiting for video frames\u2026'
            : 'ICE connected. Waiting for remote media\u2026';
      case CallPhase.mediaFlowing:
        return 'Call is running. Remote video is arriving.';
      case CallPhase.ended:
        return _endReason ?? 'Call ended.';
      case CallPhase.failed:
        return _failure ?? 'The call failed.';
    }
  }

  // -------------------------------------------------------------- user ----

  /// Starts (or accepts) a call on this phone.
  Future<void> startCall() async {
    if (_disposed || !canStart) return;
    final remoteWasReady = _phase == CallPhase.incoming && _remoteReady;
    _resetForNewCall(keepRemoteReady: remoteWasReady);
    final generation = _generation;
    _setPhase(CallPhase.preparing);

    final PeerLink link;
    try {
      link = _linkFactory();
      _link = link;
      _wire(link, generation);
      await link.open();
    } catch (error) {
      debugPrint('Opening the peer connection failed: ${error.runtimeType}');
      if (generation == _generation) {
        // Do not leave the other phone waiting if it already asked for a call.
        if (_remoteReady) {
          _send(SignalType.callReject, callReasonPayload('setup_failed'));
        }
        await _fail(
          'Could not set up the call on this phone.',
          notifyPeer: false,
        );
      }
      return;
    }
    if (generation != _generation || _disposed) return;

    _localReady = true;
    _setPhase(CallPhase.waitingForPeer);
    final sent = _send(SignalType.callReady, callReadyPayload());
    if (sent != CallSendResult.sent) {
      await _fail('Could not tell the other phone that this phone is ready.');
      return;
    }
    _enqueue(generation, _maybeCreateOffer);
  }

  /// Ends the call (or declines an incoming one) and tells the other phone.
  Future<void> hangUp() async {
    if (_disposed) return;
    if (_phase == CallPhase.incoming) {
      _send(SignalType.callReject, callReasonPayload('declined'));
      _remoteReady = false;
      _generation++;
      _endReason = 'You declined the call.';
      _setPhase(CallPhase.ended);
      return;
    }
    if (!_phase.isActive) return;
    _send(SignalType.callEnd, callReasonPayload('hangup'));
    await _finish(CallPhase.ended, reason: 'You ended the call.');
  }

  /// The signaling connection to the other phone is gone.
  Future<void> onSignalingLost() async {
    if (_disposed) return;
    if (_phase == CallPhase.incoming) {
      _remoteReady = false;
      _setPhase(CallPhase.idle);
      return;
    }
    if (!_phase.isActive) return;
    await _fail(
      'The connection to the other phone was lost, so the call was '
      'stopped. Reconnect and start the call again.',
      notifyPeer: false,
    );
  }

  /// Handles one message from the other phone. Messages are processed in
  /// order, one at a time.
  Future<void> onSignal(SignalMessage message) {
    if (_disposed) return Future<void>.value();
    final completer = Completer<void>();
    final generation = _generation;
    _tail = _tail.then((_) async {
      try {
        await _handle(message, generation);
      } catch (error) {
        debugPrint(
          'Handling ${message.type.wireName} failed: '
          '${error.runtimeType}',
        );
        if (!_disposed && _phase.isActive) {
          await _fail('The call could not be negotiated.');
        }
      } finally {
        completer.complete();
      }
    });
    return completer.future;
  }

  /// Closes the peer connection without telling the other phone.
  Future<void> shutdown() async {
    if (_disposed) return;
    _generation++;
    _cancelTimers();
    await _closeLink();
  }

  // ------------------------------------------------------------ internal --

  void _resetForNewCall({required bool keepRemoteReady}) {
    _generation++;
    _cancelTimers();
    _localReady = false;
    _remoteReady = keepRemoteReady;
    _offerSent = false;
    _offerReceived = false;
    _answerReceived = false;
    _localCandidatesReleased = false;
    _heldLocalCandidates.clear();
    _remoteCandidates.reset();
    _localCandidateCount = 0;
    _remoteCandidateCount = 0;
    _milestones = const CallMilestones();
    _snapshot = MediaSnapshot.empty;
    _failure = null;
    _endReason = null;
    _warning = null;
    // A previous phase of ended/failed/incoming may move straight on.
    if (_phase.isTerminal) _phase = CallPhase.idle;
  }

  void _wire(PeerLink link, int generation) {
    link.onLocalCandidate = (candidate) {
      if (generation != _generation) return;
      _onLocalCandidate(candidate);
    };
    link.onConnectionState = (state) {
      if (generation != _generation) return;
      _onLinkState(state);
    };
    link.onRemoteTrack = () {
      if (generation != _generation) return;
      _milestones = _milestones.copyWith(remoteTrack: true);
      _notify();
    };
    link.onMediaSnapshot = (snapshot) {
      if (generation != _generation) return;
      _onSnapshot(snapshot);
    };
  }

  void _enqueue(int generation, Future<void> Function() job) {
    _tail = _tail.then((_) async {
      if (generation != _generation || _disposed) return;
      try {
        await job();
      } catch (error) {
        debugPrint('Call step failed: ${error.runtimeType}');
        if (generation == _generation && _phase.isActive) {
          await _fail('The call could not be negotiated.');
        }
      }
    });
  }

  Future<void> _handle(SignalMessage message, int generation) async {
    switch (message.type) {
      case SignalType.callReady:
        _onCallReady(generation);
      case SignalType.offer:
        await _onOffer(message, generation);
      case SignalType.answer:
        await _onAnswer(message, generation);
      case SignalType.candidate:
        await _onCandidate(message, generation);
      case SignalType.callReject:
        await _onRemoteStop(
          message,
          'The other phone declined the call.',
          generation,
        );
      case SignalType.callEnd:
        await _onRemoteStop(
          message,
          'The other phone ended the call.',
          generation,
        );
      case SignalType.hello:
      case SignalType.helloChallenge:
      case SignalType.helloProof:
      case SignalType.helloAck:
      case SignalType.ping:
      case SignalType.pong:
      case SignalType.chat:
      case SignalType.error:
        // Not call messages; the signaling service handles them.
        break;
    }
  }

  void _onCallReady(int generation) {
    if (_remoteReady && _phase.isActive) {
      _rejectUnexpected(CallErrorCode.outOfOrder, 'call_ready arrived twice.');
      return;
    }
    if (_phase.isTerminal) {
      _resetForNewCall(keepRemoteReady: false);
      _phase = CallPhase.idle;
    }
    _remoteReady = true;
    if (_phase == CallPhase.idle) {
      _setPhase(CallPhase.incoming);
    } else {
      _notify();
    }
    if (generation == _generation) {
      _enqueue(generation, _maybeCreateOffer);
    }
  }

  Future<void> _maybeCreateOffer() async {
    if (role != NegotiationRole.offerer) return;
    if (!_localReady || !_remoteReady || _offerSent) return;
    if (_phase != CallPhase.waitingForPeer) return;
    final link = _link;
    if (link == null) return;

    _offerSent = true;
    _setPhase(CallPhase.negotiating);
    _startConnectTimer();
    final generation = _generation;
    final sdp = await link.createOffer();
    if (generation != _generation) return;
    final sent = _send(SignalType.offer, SdpPayload.offer(sdp).toPayload());
    if (sent != CallSendResult.sent) {
      await _fail(
        sent == CallSendResult.tooLarge
            ? 'The call description is too large to send.'
            : 'Could not send the call offer.',
      );
      return;
    }
    _releaseLocalCandidates();
  }

  Future<void> _onOffer(SignalMessage message, int generation) async {
    if (role != NegotiationRole.answerer) {
      _rejectUnexpected(
        CallErrorCode.wrongRole,
        'This phone creates the offer; it cannot accept one.',
      );
      return;
    }
    final link = _link;
    if (!_localReady || link == null || _phase != CallPhase.waitingForPeer) {
      _rejectUnexpected(
        CallErrorCode.notReady,
        'An offer arrived before this phone was ready.',
      );
      return;
    }
    if (_offerReceived) {
      _rejectUnexpected(CallErrorCode.outOfOrder, 'A second offer arrived.');
      return;
    }
    final SdpPayload offer;
    try {
      offer = SdpPayload.fromMessage(message);
    } on CallSignalException catch (error) {
      _rejectUnexpected(error.code, error.message);
      return;
    }

    _offerReceived = true;
    _setPhase(CallPhase.negotiating);
    _startConnectTimer();
    await link.acceptOffer(offer.sdp);
    if (generation != _generation) return;
    await _installRemoteDescription(link, generation);
    if (generation != _generation) return;

    final answerSdp = await link.createAnswer();
    if (generation != _generation) return;
    final sent = _send(
      SignalType.answer,
      SdpPayload.answer(answerSdp).toPayload(),
    );
    if (sent != CallSendResult.sent) {
      await _fail(
        sent == CallSendResult.tooLarge
            ? 'The call description is too large to send.'
            : 'Could not send the call answer.',
      );
      return;
    }
    _milestones = _milestones.copyWith(negotiated: true);
    _releaseLocalCandidates();
    _notify();
  }

  Future<void> _onAnswer(SignalMessage message, int generation) async {
    if (role != NegotiationRole.offerer) {
      _rejectUnexpected(
        CallErrorCode.wrongRole,
        'This phone creates the answer; it cannot accept one.',
      );
      return;
    }
    final link = _link;
    if (link == null || !_offerSent || _phase != CallPhase.negotiating) {
      _rejectUnexpected(
        CallErrorCode.outOfOrder,
        'An answer arrived without a pending offer.',
      );
      return;
    }
    if (_answerReceived) {
      _rejectUnexpected(CallErrorCode.outOfOrder, 'A second answer arrived.');
      return;
    }
    final SdpPayload answer;
    try {
      answer = SdpPayload.fromMessage(message);
    } on CallSignalException catch (error) {
      _rejectUnexpected(error.code, error.message);
      return;
    }

    _answerReceived = true;
    await link.acceptAnswer(answer.sdp);
    if (generation != _generation) return;
    await _installRemoteDescription(link, generation);
    if (generation != _generation) return;
    _milestones = _milestones.copyWith(negotiated: true);
    _notify();
  }

  /// Marks the remote description as installed and applies queued candidates.
  Future<void> _installRemoteDescription(PeerLink link, int generation) async {
    final queued = _remoteCandidates.open();
    for (final candidate in queued) {
      if (generation != _generation) return;
      await _applyRemoteCandidate(link, candidate);
    }
  }

  Future<void> _onCandidate(SignalMessage message, int generation) async {
    final link = _link;
    if (!_localReady || link == null || !_phase.isActive) {
      _rejectUnexpected(
        CallErrorCode.notReady,
        'A candidate arrived outside of a call.',
      );
      return;
    }
    final IceCandidatePayload candidate;
    try {
      candidate = IceCandidatePayload.fromMessage(message);
    } on CallSignalException catch (error) {
      _rejectUnexpected(error.code, error.message);
      return;
    }
    if (candidate.isEndOfCandidates) return;
    try {
      if (_remoteCandidates.submit(candidate)) {
        await _applyRemoteCandidate(link, candidate);
      }
    } on CallSignalException catch (error) {
      _rejectUnexpected(error.code, error.message);
    }
  }

  Future<void> _applyRemoteCandidate(
    PeerLink link,
    IceCandidatePayload candidate,
  ) async {
    try {
      await link.addRemoteCandidate(candidate);
      _remoteCandidateCount++;
    } catch (error) {
      // One bad candidate (for example an unusable address family) must not
      // end the call; ICE can still succeed with the others.
      debugPrint('Adding a remote candidate failed: ${error.runtimeType}');
      _warning = 'One network candidate from the other phone was rejected.';
      _notify();
    }
  }

  Future<void> _onRemoteStop(
    SignalMessage message,
    String text,
    int generation,
  ) async {
    if (_phase == CallPhase.incoming) {
      _remoteReady = false;
      _endReason = text;
      _setPhase(CallPhase.ended);
      return;
    }
    if (!_phase.isActive) return;
    final reason = callReasonOf(message);
    const plainReasons = <String>{'unspecified', 'declined', 'hangup'};
    await _finish(
      CallPhase.ended,
      reason: plainReasons.contains(reason) ? text : '$text ($reason)',
    );
  }

  void _onLocalCandidate(IceCandidatePayload candidate) {
    _localCandidateCount++;
    if (!_localCandidatesReleased) {
      if (_heldLocalCandidates.length < 128) {
        _heldLocalCandidates.add(candidate);
      }
      return;
    }
    _sendCandidate(candidate);
  }

  void _releaseLocalCandidates() {
    _localCandidatesReleased = true;
    final held = List<IceCandidatePayload>.of(_heldLocalCandidates);
    _heldLocalCandidates.clear();
    held.forEach(_sendCandidate);
  }

  void _sendCandidate(IceCandidatePayload candidate) {
    final result = _send(SignalType.candidate, candidate.toPayload());
    if (result != CallSendResult.sent && _phase.isActive) {
      _warning = 'A network candidate could not be sent.';
      _notify();
    }
  }

  void _onLinkState(LinkConnectionState state) {
    switch (state) {
      case LinkConnectionState.checking:
        if (_phase == CallPhase.negotiating) _setPhase(CallPhase.connecting);
      case LinkConnectionState.connected:
        _graceTimer?.cancel();
        _graceTimer = null;
        _connectTimer?.cancel();
        _connectTimer = null;
        if (_phase == CallPhase.negotiating) _setPhase(CallPhase.connecting);
        _milestones = _milestones.copyWith(iceConnected: true);
        if (_phase == CallPhase.connecting) {
          _setPhase(CallPhase.connected);
        } else {
          _notify();
        }
      case LinkConnectionState.disconnected:
        if (_phase == CallPhase.connected || _phase == CallPhase.mediaFlowing) {
          _milestones = _milestones.copyWith(iceConnected: false);
          _setPhase(CallPhase.connecting);
          _graceTimer?.cancel();
          _graceTimer = Timer(disconnectGrace, () {
            if (_phase == CallPhase.connecting) {
              unawaited(_fail('The connection between the phones was lost.'));
            }
          });
        }
      case LinkConnectionState.failed:
        if (_phase.isActive) {
          unawaited(
            _fail(
              'The phones could not find a network path to each other '
              '($_localCandidateCount local / $_remoteCandidateCount remote '
              'candidates). Some hotspots block traffic between connected '
              'phones; try the other phone as host.',
            ),
          );
        }
      case LinkConnectionState.closed:
        break;
    }
  }

  void _onSnapshot(MediaSnapshot snapshot) {
    if (!_phase.isActive) return;
    final changed = snapshot != _snapshot;
    _snapshot = snapshot;
    final video = snapshot.receivedVideoFrames > 0;
    final audio = snapshot.receivedAudioBytes > 0;
    if (video != _milestones.remoteVideoFrames ||
        audio != _milestones.remoteAudioFlowing) {
      _milestones = _milestones.copyWith(
        remoteVideoFrames: video,
        remoteAudioFlowing: audio,
      );
    }
    if (video && _phase == CallPhase.connected) {
      _setPhase(CallPhase.mediaFlowing);
      return;
    }
    if (changed) _notify();
  }

  void _startConnectTimer() {
    _connectTimer?.cancel();
    _connectTimer = Timer(connectTimeout, () {
      if (_phase == CallPhase.negotiating || _phase == CallPhase.connecting) {
        unawaited(
          _fail(
            'The call did not connect in time. Check that both phones are '
            'on the same hotspot and that the hotspot allows phones to '
            'reach each other.',
          ),
        );
      }
    });
  }

  void _rejectUnexpected(String code, String text) {
    _warning = text;
    _send(SignalType.error, <String, Object?>{'code': code, 'message': text});
    _notify();
  }

  Future<void> _fail(String message, {bool notifyPeer = true}) async {
    if (_disposed || (!_phase.isActive && _phase != CallPhase.incoming)) {
      return;
    }
    if (notifyPeer) _send(SignalType.callEnd, callReasonPayload('failed'));
    _failure = message;
    await _finish(CallPhase.failed, reason: null);
  }

  Future<void> _finish(CallPhase terminal, {required String? reason}) async {
    _generation++;
    _cancelTimers();
    if (terminal == CallPhase.ended) _endReason = reason;
    _remoteReady = false;
    _localReady = false;
    _setPhase(terminal);
    await _closeLink();
  }

  Future<void> _closeLink() async {
    final link = _link;
    _link = null;
    if (link == null) return;
    link.onLocalCandidate = null;
    link.onConnectionState = null;
    link.onRemoteTrack = null;
    link.onMediaSnapshot = null;
    try {
      await link.close();
    } catch (error) {
      debugPrint('Closing the peer link failed: ${error.runtimeType}');
    }
  }

  void _cancelTimers() {
    _connectTimer?.cancel();
    _connectTimer = null;
    _graceTimer?.cancel();
    _graceTimer = null;
  }

  void _setPhase(CallPhase next) {
    if (!_phase.canMoveTo(next)) {
      debugPrint('Ignored call phase change $_phase -> $next');
      return;
    }
    _phase = next;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _cancelTimers();
    unawaited(_closeLink());
    super.dispose();
  }
}

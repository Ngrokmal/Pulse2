import 'signal_message.dart';

/// Longest accepted SDP text, in characters. The whole signaling message
/// (envelope included) must stay under [kMaxSignalMessageChars].
const int kMaxSdpChars = 14 * 1024;

/// Longest accepted ICE candidate line.
const int kMaxCandidateChars = 1024;

const int kMaxMidChars = 64;
const int kMaxMLineIndex = 64;
const int kMaxReasonChars = 64;

/// Error codes for call negotiation problems (sent in `error` messages).
abstract final class CallErrorCode {
  static const String invalidSdp = 'invalid_sdp';
  static const String invalidCandidate = 'invalid_candidate';
  static const String outOfOrder = 'negotiation_out_of_order';
  static const String notReady = 'call_not_ready';
  static const String wrongRole = 'wrong_negotiation_role';
}

/// Thrown when a call message has missing or malformed fields.
class CallSignalException implements Exception {
  const CallSignalException(this.code, this.message);

  /// One of [CallErrorCode].
  final String code;
  final String message;

  @override
  String toString() => 'CallSignalException($code): $message';
}

/// Message types that belong to call negotiation.
const Set<SignalType> kCallSignalTypes = <SignalType>{
  SignalType.offer,
  SignalType.answer,
  SignalType.candidate,
  SignalType.callReady,
  SignalType.callReject,
  SignalType.callEnd,
};

bool isCallSignal(SignalType type) => kCallSignalTypes.contains(type);

/// Result of trying to send a call message.
enum CallSendResult { sent, notConnected, tooLarge, notACallMessage }

/// An SDP offer or answer.
///
/// Wire payload: `{"type":"offer"|"answer","sdp":"v=0..."}`
class SdpPayload {
  const SdpPayload({required this.type, required this.sdp});

  factory SdpPayload.offer(String sdp) =>
      SdpPayload(type: SignalType.offer, sdp: sdp);

  factory SdpPayload.answer(String sdp) =>
      SdpPayload(type: SignalType.answer, sdp: sdp);

  /// Validates a received `offer` or `answer` message.
  factory SdpPayload.fromMessage(SignalMessage message) {
    final type = message.type;
    if (type != SignalType.offer && type != SignalType.answer) {
      throw CallSignalException(
        CallErrorCode.invalidSdp,
        'A ${type.wireName} message does not carry an SDP.',
      );
    }
    final declared = message.payload['type'];
    if (declared != type.wireName) {
      throw CallSignalException(
        CallErrorCode.invalidSdp,
        'SDP type does not match the message type.',
      );
    }
    final sdp = message.payload['sdp'];
    if (sdp is! String || sdp.isEmpty) {
      throw const CallSignalException(
        CallErrorCode.invalidSdp,
        'The SDP is missing.',
      );
    }
    if (sdp.length > kMaxSdpChars) {
      throw const CallSignalException(
        CallErrorCode.invalidSdp,
        'The SDP is too large.',
      );
    }
    if (!sdp.startsWith('v=0')) {
      throw const CallSignalException(
        CallErrorCode.invalidSdp,
        'The SDP does not look like a session description.',
      );
    }
    return SdpPayload(type: type, sdp: sdp);
  }

  /// [SignalType.offer] or [SignalType.answer].
  final SignalType type;
  final String sdp;

  Map<String, Object?> toPayload() => <String, Object?>{
    'type': type.wireName,
    'sdp': sdp,
  };
}

/// One ICE candidate.
///
/// Wire payload: `{"candidate":"candidate:...","sdpMid":"0","sdpMLineIndex":0}`
/// An empty `candidate` string means "end of candidates".
class IceCandidatePayload {
  const IceCandidatePayload({
    required this.candidate,
    this.sdpMid,
    this.sdpMLineIndex,
  });

  factory IceCandidatePayload.fromMessage(SignalMessage message) {
    if (message.type != SignalType.candidate) {
      throw CallSignalException(
        CallErrorCode.invalidCandidate,
        'A ${message.type.wireName} message does not carry a candidate.',
      );
    }
    final candidate = message.payload['candidate'];
    if (candidate is! String) {
      throw const CallSignalException(
        CallErrorCode.invalidCandidate,
        'The candidate is missing.',
      );
    }
    if (candidate.length > kMaxCandidateChars) {
      throw const CallSignalException(
        CallErrorCode.invalidCandidate,
        'The candidate is too long.',
      );
    }
    if (candidate.isNotEmpty && !candidate.startsWith('candidate:')) {
      throw const CallSignalException(
        CallErrorCode.invalidCandidate,
        'The candidate has an unexpected format.',
      );
    }

    final mid = message.payload['sdpMid'];
    if (mid != null && (mid is! String || mid.length > kMaxMidChars)) {
      throw const CallSignalException(
        CallErrorCode.invalidCandidate,
        'The candidate sdpMid is invalid.',
      );
    }
    final index = message.payload['sdpMLineIndex'];
    if (index != null &&
        (index is! int || index < 0 || index > kMaxMLineIndex)) {
      throw const CallSignalException(
        CallErrorCode.invalidCandidate,
        'The candidate sdpMLineIndex is invalid.',
      );
    }
    if (candidate.isNotEmpty && mid == null && index == null) {
      throw const CallSignalException(
        CallErrorCode.invalidCandidate,
        'The candidate needs an sdpMid or an sdpMLineIndex.',
      );
    }
    return IceCandidatePayload(
      candidate: candidate,
      sdpMid: mid as String?,
      sdpMLineIndex: index as int?,
    );
  }

  final String candidate;
  final String? sdpMid;
  final int? sdpMLineIndex;

  bool get isEndOfCandidates => candidate.isEmpty;

  /// Candidate kind from the line (`host`, `srflx`, `prflx`, `relay`), if any.
  /// Used for diagnostics only; addresses are never inspected or logged.
  String? get candidateType {
    final match = RegExp(r' typ (\w+)').firstMatch(candidate);
    return match?.group(1);
  }

  Map<String, Object?> toPayload() => <String, Object?>{
    'candidate': candidate,
    'sdpMid': sdpMid,
    'sdpMLineIndex': sdpMLineIndex,
  };
}

/// Reads the optional short `reason` of `call_reject` / `call_end`.
String callReasonOf(SignalMessage message) {
  final reason = message.payload['reason'];
  if (reason is String &&
      reason.isNotEmpty &&
      reason.length <= kMaxReasonChars) {
    return reason;
  }
  return 'unspecified';
}

/// Payload of `call_ready`: what media this phone will send.
Map<String, Object?> callReadyPayload({bool audio = true, bool video = true}) =>
    <String, Object?>{'audio': audio, 'video': video};

Map<String, Object?> callReasonPayload(String reason) => <String, Object?>{
  'reason': reason,
};

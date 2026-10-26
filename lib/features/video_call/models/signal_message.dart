import 'dart:convert';

/// Version of the JSON signaling protocol spoken by this app.
///
/// Version 2 replaced the clear-text pairing code in `hello` with a mutual
/// challenge-response handshake (`hello_challenge`, `hello_proof`).
const int kSignalProtocolVersion = 2;

/// Longest accepted raw message, in characters. Larger messages are rejected.
const int kMaxSignalMessageChars = 16 * 1024;

/// Longest accepted id string (session id, sender id).
const int kMaxSignalIdChars = 64;

/// Longest accepted test (chat) message, in characters.
const int kMaxChatChars = 1000;

/// Machine-readable error codes sent in `error` messages.
abstract final class SignalErrorCode {
  static const String malformed = 'malformed_message';
  static const String tooLarge = 'message_too_large';
  static const String protocolMismatch = 'protocol_mismatch';
  static const String badPairingCode = 'bad_pairing_code';
  static const String hostBusy = 'host_busy';
  static const String handshakeTimeout = 'handshake_timeout';
  static const String unexpectedMessage = 'unexpected_message';
  static const String sessionMismatch = 'session_mismatch';
}

enum SignalType {
  hello('hello'),
  helloChallenge('hello_challenge'),
  helloProof('hello_proof'),
  helloAck('hello_ack'),
  ping('ping'),
  pong('pong'),
  chat('chat'),
  error('error'),

  // Phase 3: WebRTC call negotiation. Same envelope, same session checks.
  offer('offer'),
  answer('answer'),
  candidate('candidate'),
  callReady('call_ready'),
  callReject('call_reject'),
  callEnd('call_end');

  const SignalType(this.wireName);

  final String wireName;

  static SignalType? fromWireName(Object? name) {
    for (final type in SignalType.values) {
      if (type.wireName == name) return type;
    }
    return null;
  }
}

/// Thrown when incoming data is not a valid signaling message.
class SignalFormatException implements Exception {
  const SignalFormatException(this.code, this.message);

  /// One of [SignalErrorCode].
  final String code;
  final String message;

  @override
  String toString() => 'SignalFormatException($code): $message';
}

/// One signaling message.
///
/// Wire format (JSON text):
/// `{"v":2,"type":"chat","session":"...","sender":"...","payload":{...}}`
class SignalMessage {
  const SignalMessage({
    required this.type,
    required this.sessionId,
    required this.senderId,
    this.payload = const <String, Object?>{},
    this.version = kSignalProtocolVersion,
  });

  factory SignalMessage.error({
    required String senderId,
    required String code,
    required String message,
    String sessionId = '',
  }) {
    return SignalMessage(
      type: SignalType.error,
      sessionId: sessionId,
      senderId: senderId,
      payload: <String, Object?>{'code': code, 'message': message},
    );
  }

  /// Parses and validates raw data received from a socket.
  ///
  /// Throws [SignalFormatException] for anything that is not a well-formed
  /// message of the supported protocol version.
  factory SignalMessage.decode(Object? raw) {
    if (raw is! String) {
      throw const SignalFormatException(
        SignalErrorCode.malformed,
        'Only text messages are supported.',
      );
    }
    if (raw.length > kMaxSignalMessageChars) {
      throw const SignalFormatException(
        SignalErrorCode.tooLarge,
        'Message is too large.',
      );
    }

    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException {
      throw const SignalFormatException(
        SignalErrorCode.malformed,
        'Message is not valid JSON.',
      );
    }
    if (json is! Map<String, dynamic>) {
      throw const SignalFormatException(
        SignalErrorCode.malformed,
        'Message must be a JSON object.',
      );
    }

    final version = json['v'];
    if (version is! int) {
      throw const SignalFormatException(
        SignalErrorCode.malformed,
        'Missing protocol version.',
      );
    }
    if (version != kSignalProtocolVersion) {
      throw SignalFormatException(
        SignalErrorCode.protocolMismatch,
        'Protocol version $version is not supported '
        '(this app uses $kSignalProtocolVersion).',
      );
    }

    final type = SignalType.fromWireName(json['type']);
    if (type == null) {
      throw const SignalFormatException(
        SignalErrorCode.malformed,
        'Unknown or missing message type.',
      );
    }

    final session = json['session'];
    if (session is! String || session.length > kMaxSignalIdChars) {
      throw const SignalFormatException(
        SignalErrorCode.malformed,
        'Missing or invalid session id.',
      );
    }

    final sender = json['sender'];
    if (sender is! String ||
        sender.isEmpty ||
        sender.length > kMaxSignalIdChars) {
      throw const SignalFormatException(
        SignalErrorCode.malformed,
        'Missing or invalid sender id.',
      );
    }

    final rawPayload = json['payload'];
    final Map<String, Object?> payload;
    if (rawPayload == null) {
      payload = const <String, Object?>{};
    } else if (rawPayload is Map<String, dynamic>) {
      payload = rawPayload;
    } else {
      throw const SignalFormatException(
        SignalErrorCode.malformed,
        'Payload must be a JSON object.',
      );
    }

    return SignalMessage(
      type: type,
      sessionId: session,
      senderId: sender,
      payload: payload,
      version: version,
    );
  }

  final int version;
  final SignalType type;

  /// Empty before a session exists (first `hello`, early errors).
  final String sessionId;
  final String senderId;
  final Map<String, Object?> payload;

  Map<String, Object?> toJson() => <String, Object?>{
    'v': version,
    'type': type.wireName,
    'session': sessionId,
    'sender': senderId,
    'payload': payload,
  };

  String encode() => jsonEncode(toJson());
}

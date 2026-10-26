import 'connection_validators.dart';
import 'session_tokens.dart';

/// Longest QR text the app will look at. A real payload is under 80
/// characters; anything much longer is not ours.
const int kMaxPairingPayloadChars = 128;

/// Current QR payload version.
const int kPairingPayloadVersion = 1;

/// Thrown for a QR text that must not be used. [message] is safe to show:
/// it never repeats the scanned text.
class PairingPayloadException implements Exception {
  const PairingPayloadException(this.message);

  final String message;

  @override
  String toString() => 'PairingPayloadException($message)';
}

/// What the host puts in its QR code: where to connect and the session
/// secret. Wire form (plain text, no URL, nothing external):
///
///     ovc1;<IPv4 address>;<port>;<32 hex characters>
///
/// The QR code is shown on the host's screen only. It is built in memory
/// and is never logged, stored or sent anywhere.
class PairingPayload {
  const PairingPayload({
    required this.host,
    required this.port,
    required this.secret,
  });

  /// Parses and validates scanned text. Throws [PairingPayloadException].
  factory PairingPayload.parse(String? raw) {
    if (raw == null || raw.isEmpty) {
      throw const PairingPayloadException('The QR code is empty.');
    }
    if (raw.length > kMaxPairingPayloadChars) {
      throw const PairingPayloadException(
        'This QR code is too large to be an Offline Video Call code.',
      );
    }
    final parts = raw.split(';');
    final tag = parts.first;
    final versionMatch = RegExp(r'^ovc([0-9]{1,3})$').firstMatch(tag);
    if (versionMatch == null) {
      throw const PairingPayloadException(
        'This is not an Offline Video Call QR code.',
      );
    }
    final version = int.parse(versionMatch.group(1)!);
    if (version != kPairingPayloadVersion) {
      throw const PairingPayloadException(
        'This QR code was made by a different app version. Install the same '
        'version on both phones.',
      );
    }
    if (parts.length != 4) {
      throw const PairingPayloadException('The QR code is damaged.');
    }
    final host = parts[1];
    if (validateIPv4Address(host) != null) {
      throw const PairingPayloadException(
        'The QR code does not contain a valid address.',
      );
    }
    if (!isPrivateLanIPv4(host)) {
      throw const PairingPayloadException(
        'The QR code points outside the local network, so it was refused.',
      );
    }
    final port = parsePort(parts[2]);
    if (port == null || port < kMinHostPort) {
      throw const PairingPayloadException(
        'The QR code does not contain a valid port.',
      );
    }
    final secret = parts[3];
    if (!isValidSessionSecret(secret)) {
      throw const PairingPayloadException(
        'The QR code does not contain a valid pairing credential.',
      );
    }
    return PairingPayload(host: host, port: port, secret: secret);
  }

  final String host;
  final int port;
  final String secret;

  /// The text to render as a QR code. Contains the secret: never log it.
  String encode() => 'ovc$kPairingPayloadVersion;$host;$port;$secret';

  /// Safe description for confirmation dialogs (no secret).
  String get endpoint => '$host:$port';

  @override
  String toString() => 'PairingPayload($endpoint, secret: hidden)';
}

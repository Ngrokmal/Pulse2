import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Which secret a joining phone proves it knows.
enum CredentialMode {
  /// The 128-bit session secret from the QR code.
  secret('secret'),

  /// The short 6-digit code typed by hand (weaker; see docs/security.md).
  code('code');

  const CredentialMode(this.wireName);

  final String wireName;

  static CredentialMode? fromWireName(Object? name) {
    for (final mode in CredentialMode.values) {
      if (mode.wireName == name) return mode;
    }
    return null;
  }
}

/// MAC labels. Different labels make the two directions non-interchangeable,
/// so a proof captured from one side cannot be replayed as the other.
const String kClientProofLabel = 'ovc-client-proof';
const String kHostProofLabel = 'ovc-host-proof';

/// Key material for a credential. The mode is part of the key so a code
/// proof can never be mistaken for a secret proof.
List<int> credentialKey(CredentialMode mode, String credential) =>
    utf8.encode('ovc-${mode.wireName}:$credential');

/// HMAC-SHA256 (lowercase hex) over everything that identifies this
/// handshake. Fields are length-prefixed so no field can bleed into another.
///
/// The credential itself is never sent: only this MAC is.
String handshakeMac({
  required List<int> key,
  required String label,
  required String clientNonce,
  required String hostNonce,
  required String clientId,
  required String hostId,
  required String sessionId,
}) {
  final fields = <String>[
    label,
    clientNonce,
    hostNonce,
    clientId,
    hostId,
    sessionId,
  ];
  final data = StringBuffer();
  for (final field in fields) {
    data
      ..write(field.length)
      ..write(':')
      ..write(field)
      ..write(';');
  }
  return Hmac(sha256, key).convert(utf8.encode(data.toString())).toString();
}

/// True when [input] looks like an HMAC-SHA256 hex digest.
bool isValidMac(Object? input) =>
    input is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(input);

/// Compares two strings in time that does not depend on where they differ.
bool constantTimeEquals(String expected, String actual) {
  if (expected.length != actual.length) return false;
  var difference = 0;
  for (var i = 0; i < expected.length; i++) {
    difference |= expected.codeUnitAt(i) ^ actual.codeUnitAt(i);
  }
  return difference == 0;
}

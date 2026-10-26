import 'dart:math';

/// Number of digits in the pairing code shown by the host.
const int kPairingCodeLength = 6;

/// Creates a random numeric pairing code (leading zeros allowed).
String generatePairingCode([Random? random]) {
  final source = random ?? Random.secure();
  return List<String>.generate(
    kPairingCodeLength,
    (_) => source.nextInt(10).toString(),
  ).join();
}

/// Creates a random lowercase-hex id, [byteCount] bytes long.
String generateId({int byteCount = 8, Random? random}) {
  final source = random ?? Random.secure();
  return List<String>.generate(
    byteCount,
    (_) => source.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

/// Returns an error text for form fields, or null when [input] is valid.
String? validatePairingCode(String? input) {
  final value = input?.trim() ?? '';
  if (value.isEmpty) return 'Enter the pairing code shown on the host.';
  if (!RegExp('^[0-9]{$kPairingCodeLength}\$').hasMatch(value)) {
    return 'The pairing code has $kPairingCodeLength digits.';
  }
  return null;
}

/// Compares two codes without stopping at the first different character.
bool pairingCodesMatch(String expected, String actual) {
  if (expected.length != actual.length) return false;
  var difference = 0;
  for (var i = 0; i < expected.length; i++) {
    difference |= expected.codeUnitAt(i) ^ actual.codeUnitAt(i);
  }
  return difference == 0;
}

/// Number of random bytes in the session secret shown in the QR code.
const int kSessionSecretBytes = 16;

/// Creates the strong session secret (128 random bits, 32 lowercase hex
/// characters) used for QR pairing. Uses `Random.secure()` unless a test
/// supplies its own source.
String generateSessionSecret([Random? random]) =>
    generateId(byteCount: kSessionSecretBytes, random: random);

/// True when [input] has the shape of a session secret.
bool isValidSessionSecret(Object? input) =>
    input is String && RegExp(r'^[0-9a-f]{32}$').hasMatch(input);

/// True when [input] has the shape of a handshake nonce (16 random bytes).
bool isValidNonce(Object? input) =>
    input is String && RegExp(r'^[0-9a-f]{32}$').hasMatch(input);

/// Creates a fresh handshake nonce.
String generateNonce([Random? random]) =>
    generateId(byteCount: 16, random: random);

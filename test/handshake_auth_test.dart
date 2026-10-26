// Unit tests for the handshake MAC, token generation, QR payload parsing and
// address checks. They check the logic with fixed inputs; they do not prove
// the protocol is secure against every attack.
// ignore_for_file: avoid_relative_lib_imports
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import '../lib/features/video_call/models/connection_validators.dart';
import '../lib/features/video_call/models/handshake_auth.dart';
import '../lib/features/video_call/models/pairing_payload.dart';
import '../lib/features/video_call/models/session_tokens.dart';

const String _secret = '0123456789abcdef0123456789abcdef';

String _mac({
  List<int>? key,
  String label = kClientProofLabel,
  String cn = 'aa',
  String sn = 'bb',
  String client = 'c1',
  String host = 'h1',
  String session = 's1',
}) {
  return handshakeMac(
    key: key ?? credentialKey(CredentialMode.secret, _secret),
    label: label,
    clientNonce: cn,
    hostNonce: sn,
    clientId: client,
    hostId: host,
    sessionId: session,
  );
}

void main() {
  group('session secret and nonce', () {
    test('secret has 128 bits as 32 lowercase hex characters', () {
      final value = generateSessionSecret();
      expect(value, hasLength(32));
      expect(isValidSessionSecret(value), isTrue);
    });

    test('secrets and nonces are not repeated', () {
      final secrets = {for (var i = 0; i < 50; i++) generateSessionSecret()};
      final nonces = {for (var i = 0; i < 50; i++) generateNonce()};
      expect(secrets, hasLength(50));
      expect(nonces, hasLength(50));
    });

    test('generation can use an injected random source', () {
      expect(
        generateSessionSecret(Random(1)),
        generateSessionSecret(Random(1)),
      );
    });

    test('shape checks reject wrong values', () {
      for (final bad in <Object?>[
        null,
        42,
        '',
        'abc',
        _secret.toUpperCase(),
        '${_secret}0',
        _secret.substring(1),
        'g${_secret.substring(1)}',
      ]) {
        expect(isValidSessionSecret(bad), isFalse, reason: '$bad');
        expect(isValidNonce(bad), isFalse, reason: '$bad');
      }
    });
  });

  group('handshakeMac', () {
    test('is deterministic and 64 hex characters', () {
      final a = _mac();
      expect(a, _mac());
      expect(isValidMac(a), isTrue);
    });

    test('changes when any single input changes', () {
      final base = _mac();
      expect(_mac(label: kHostProofLabel), isNot(base));
      expect(_mac(cn: 'ab'), isNot(base));
      expect(_mac(sn: 'bc'), isNot(base));
      expect(_mac(client: 'c2'), isNot(base));
      expect(_mac(host: 'h2'), isNot(base));
      expect(_mac(session: 's2'), isNot(base));
      expect(
        _mac(key: credentialKey(CredentialMode.secret, '${_secret}x')),
        isNot(base),
      );
    });

    test('a code and a secret with the same text give different keys', () {
      expect(
        _mac(key: credentialKey(CredentialMode.code, '123456')),
        isNot(_mac(key: credentialKey(CredentialMode.secret, '123456'))),
      );
    });

    test('fields cannot be shifted into each other', () {
      expect(_mac(cn: 'a', sn: 'bc'), isNot(_mac(cn: 'ab', sn: 'c')));
    });

    test('isValidMac rejects wrong shapes', () {
      for (final bad in <Object?>[null, 5, '', 'zz', 'A' * 64, 'a' * 63]) {
        expect(isValidMac(bad), isFalse, reason: '$bad');
      }
    });

    test('constantTimeEquals compares whole strings', () {
      expect(constantTimeEquals('abc', 'abc'), isTrue);
      expect(constantTimeEquals('abc', 'abd'), isFalse);
      expect(constantTimeEquals('abc', 'abcd'), isFalse);
      expect(constantTimeEquals('', ''), isTrue);
    });

    test('credential modes round-trip by wire name', () {
      expect(CredentialMode.fromWireName('secret'), CredentialMode.secret);
      expect(CredentialMode.fromWireName('code'), CredentialMode.code);
      expect(CredentialMode.fromWireName('other'), isNull);
      expect(CredentialMode.fromWireName(null), isNull);
    });
  });

  group('PairingPayload', () {
    final valid = 'ovc1;192.168.43.1;8080;$_secret';

    test('parses a valid payload', () {
      final payload = PairingPayload.parse(valid);
      expect(payload.host, '192.168.43.1');
      expect(payload.port, 8080);
      expect(payload.secret, _secret);
      expect(payload.endpoint, '192.168.43.1:8080');
    });

    test('encode and parse round-trip', () {
      const original = PairingPayload(
        host: '10.0.0.7',
        port: 54321,
        secret: _secret,
      );
      final parsed = PairingPayload.parse(original.encode());
      expect(parsed.host, original.host);
      expect(parsed.port, original.port);
      expect(parsed.secret, original.secret);
    });

    test('toString never contains the secret', () {
      expect(PairingPayload.parse(valid).toString(), isNot(contains(_secret)));
    });

    void expectRejected(String? raw, {String? messageContains}) {
      try {
        PairingPayload.parse(raw);
        fail('Expected a PairingPayloadException for: $raw');
      } on PairingPayloadException catch (error) {
        // The message must never repeat the scanned text.
        if (raw != null && raw.length > 3) {
          expect(error.message, isNot(contains(raw)));
        }
        expect(error.message, isNot(contains(_secret)));
        if (messageContains != null) {
          expect(error.message, contains(messageContains));
        }
      }
    }

    test('rejects empty, foreign and oversized text', () {
      expectRejected(null);
      expectRejected('');
      expectRejected('https://example.com/join');
      expectRejected('hello world', messageContains: 'not an Offline');
      expectRejected(
        'x' * (kMaxPairingPayloadChars + 1),
        messageContains: 'too large',
      );
    });

    test('rejects unsupported versions', () {
      expectRejected(
        'ovc2;192.168.43.1;8080;$_secret',
        messageContains: 'different app version',
      );
      expectRejected(
        'ovc0;192.168.43.1;8080;$_secret',
        messageContains: 'different app version',
      );
      expectRejected(
        'ovc99;192.168.43.1;8080;$_secret',
        messageContains: 'different app version',
      );
    });

    test('rejects the wrong number of fields', () {
      expectRejected('ovc1;192.168.43.1;8080');
      expectRejected('ovc1;192.168.43.1;8080;$_secret;extra');
      expectRejected('ovc1');
    });

    test('rejects invalid or non-local addresses', () {
      expectRejected('ovc1;999.1.1.1;8080;$_secret');
      expectRejected('ovc1;192.168.43;8080;$_secret');
      expectRejected('ovc1;example.com;8080;$_secret');
      expectRejected(
        'ovc1;8.8.8.8;8080;$_secret',
        messageContains: 'outside the local network',
      );
      expectRejected('ovc1;127.0.0.1;8080;$_secret');
      expectRejected('ovc1;0.0.0.0;8080;$_secret');
      expectRejected('ovc1;172.32.0.1;8080;$_secret');
    });

    test('rejects invalid ports', () {
      for (final port in [
        '0',
        '80',
        '1023',
        '65536',
        '-1',
        'abc',
        '',
        '8o8o',
      ]) {
        expectRejected('ovc1;192.168.43.1;$port;$_secret');
      }
      expect(
        PairingPayload.parse('ovc1;192.168.43.1;1024;$_secret').port,
        1024,
      );
      expect(
        PairingPayload.parse('ovc1;192.168.43.1;65535;$_secret').port,
        65535,
      );
    });

    test('rejects malformed credentials', () {
      expectRejected('ovc1;192.168.43.1;8080;');
      expectRejected('ovc1;192.168.43.1;8080;123456');
      expectRejected('ovc1;192.168.43.1;8080;${_secret.toUpperCase()}');
      expectRejected('ovc1;192.168.43.1;8080;${_secret}00');
    });
  });

  group('local address checks', () {
    test('private LAN ranges', () {
      for (final ip in [
        '10.0.0.1',
        '10.255.255.254',
        '172.16.0.1',
        '172.31.255.1',
        '192.168.0.1',
        '192.168.43.1',
        '169.254.10.10',
      ]) {
        expect(isPrivateLanIPv4(ip), isTrue, reason: ip);
      }
    });

    test('public, carrier, loopback and malformed addresses are not LAN', () {
      for (final ip in [
        '8.8.8.8',
        '172.15.0.1',
        '172.32.0.1',
        '192.169.0.1',
        '100.64.0.1',
        '127.0.0.1',
        '',
        'abc',
        '10.0.0',
      ]) {
        expect(isPrivateLanIPv4(ip), isFalse, reason: ip);
      }
    });

    test('the host serves LAN peers and itself, nothing else', () {
      expect(isAllowedPeerAddress('192.168.43.20'), isTrue);
      expect(isAllowedPeerAddress('127.0.0.1'), isTrue);
      expect(isAllowedPeerAddress('8.8.8.8'), isFalse);
      expect(isAllowedPeerAddress('100.64.1.1'), isFalse);
      expect(isAllowedPeerAddress(null), isFalse);
      expect(isAllowedPeerAddress(''), isFalse);
    });
  });
}

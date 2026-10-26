// ignore_for_file: avoid_relative_lib_imports
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import '../lib/features/video_call/models/connection_validators.dart';
import '../lib/features/video_call/models/session_tokens.dart';
import '../lib/features/video_call/services/network_discovery_service.dart';

void main() {
  group('IPv4 validation', () {
    test('accepts normal addresses, also with surrounding spaces', () {
      for (final ip in [
        '192.168.43.1',
        '10.0.0.5',
        '172.20.10.1',
        '127.0.0.1',
        ' 192.168.1.20 ',
      ]) {
        expect(validateIPv4Address(ip), isNull, reason: ip);
      }
    });

    test('rejects malformed addresses', () {
      for (final ip in [
        '',
        '   ',
        '192.168.1',
        '192.168.1.1.1',
        '192.168.1.256',
        '192.168.01.1',
        '192.168..1',
        'a.b.c.d',
        '192.168.1.-1',
        '0.0.0.0',
        '224.0.0.1',
        '255.255.255.255',
      ]) {
        expect(validateIPv4Address(ip), isNotNull, reason: ip);
      }
      expect(validateIPv4Address(null), isNotNull);
    });
  });

  group('port validation', () {
    test('parsePort accepts 1..65535 only', () {
      expect(parsePort('8080'), 8080);
      expect(parsePort(' 65535 '), 65535);
      expect(parsePort('1'), 1);
      expect(parsePort('0'), isNull);
      expect(parsePort('65536'), isNull);
      expect(parsePort('-1'), isNull);
      expect(parsePort('80a'), isNull);
      expect(parsePort(''), isNull);
      expect(parsePort(null), isNull);
    });

    test('field validators return messages for bad ports', () {
      expect(validatePortNumber('8080'), isNull);
      expect(validatePortNumber('99999'), isNotNull);
      expect(validateHostPortNumber('1024'), isNull);
      expect(validateHostPortNumber('1023'), isNotNull);
      expect(validateHostPortNumber('abc'), isNotNull);
    });
  });

  group('pairing code / session tokens', () {
    test('generated pairing code has 6 digits', () {
      for (var seed = 0; seed < 20; seed++) {
        final code = generatePairingCode(Random(seed));
        expect(code, matches(RegExp(r'^[0-9]{6}$')));
        expect(validatePairingCode(code), isNull);
      }
    });

    test('generated ids are hex of the requested length', () {
      final id = generateId(byteCount: 8, random: Random(1));
      expect(id, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(generateId(byteCount: 8), isNot(equals(generateId(byteCount: 8))));
    });

    test('validatePairingCode', () {
      expect(validatePairingCode('012345'), isNull);
      expect(validatePairingCode(' 123456 '), isNull);
      expect(validatePairingCode(''), isNotNull);
      expect(validatePairingCode('12345'), isNotNull);
      expect(validatePairingCode('1234567'), isNotNull);
      expect(validatePairingCode('12a456'), isNotNull);
      expect(validatePairingCode(null), isNotNull);
    });

    test('pairingCodesMatch', () {
      expect(pairingCodesMatch('123456', '123456'), isTrue);
      expect(pairingCodesMatch('123456', '123457'), isFalse);
      expect(pairingCodesMatch('123456', '12345'), isFalse);
      expect(pairingCodesMatch('123456', ''), isFalse);
    });
  });

  group('interface classification', () {
    test('guesses from common Android interface names', () {
      expect(
        NetworkDiscoveryService.classify('ap0'),
        AddressKind.hotspotLikely,
      );
      expect(
        NetworkDiscoveryService.classify('swlan0'),
        AddressKind.hotspotLikely,
      );
      expect(NetworkDiscoveryService.classify('wlan0'), AddressKind.wifi);
      expect(
        NetworkDiscoveryService.classify('rmnet_data1'),
        AddressKind.mobileData,
      );
      expect(
        NetworkDiscoveryService.classify('ccmni1'),
        AddressKind.mobileData,
      );
      expect(NetworkDiscoveryService.classify('tun0'), AddressKind.other);
    });
  });
}

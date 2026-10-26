// ignore_for_file: avoid_relative_lib_imports
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../lib/features/video_call/models/signal_message.dart';

Matcher _formatError(String code) =>
    throwsA(isA<SignalFormatException>().having((e) => e.code, 'code', code));

String _json(Map<String, Object?> overrides, {List<String> remove = const []}) {
  final map = <String, Object?>{
    'v': kSignalProtocolVersion,
    'type': 'hello',
    'session': 'abc',
    'sender': 'sender1',
    'payload': <String, Object?>{},
    ...overrides,
  };
  for (final key in remove) {
    map.remove(key);
  }
  return jsonEncode(map);
}

void main() {
  group('SignalMessage encode/decode', () {
    test('round trip keeps every field', () {
      const original = SignalMessage(
        type: SignalType.chat,
        sessionId: 'session1',
        senderId: 'sender1',
        payload: <String, Object?>{'text': 'hi'},
      );
      final decoded = SignalMessage.decode(original.encode());
      expect(decoded.version, kSignalProtocolVersion);
      expect(decoded.type, SignalType.chat);
      expect(decoded.sessionId, 'session1');
      expect(decoded.senderId, 'sender1');
      expect(decoded.payload['text'], 'hi');
    });

    test('every message type has its own wire name', () {
      final names = SignalType.values.map((t) => t.wireName).toSet();
      expect(names.length, SignalType.values.length);
      expect(
        names,
        containsAll(<String>[
          'hello',
          'hello_ack',
          'ping',
          'pong',
          'chat',
          'error',
        ]),
      );
      for (final type in SignalType.values) {
        expect(SignalType.fromWireName(type.wireName), type);
      }
    });

    test('empty session id is allowed (first hello)', () {
      final decoded = SignalMessage.decode(_json({'session': ''}));
      expect(decoded.sessionId, isEmpty);
    });

    test('missing payload becomes an empty map', () {
      final decoded = SignalMessage.decode(_json({}, remove: ['payload']));
      expect(decoded.payload, isEmpty);
    });

    test('error factory carries code and message', () {
      final message = SignalMessage.error(
        senderId: 's',
        code: SignalErrorCode.hostBusy,
        message: 'busy',
      );
      final decoded = SignalMessage.decode(message.encode());
      expect(decoded.type, SignalType.error);
      expect(decoded.payload['code'], SignalErrorCode.hostBusy);
    });
  });

  group('SignalMessage rejects invalid data', () {
    test('non-text data', () {
      expect(
        () => SignalMessage.decode(<int>[1, 2, 3]),
        _formatError(SignalErrorCode.malformed),
      );
      expect(
        () => SignalMessage.decode(null),
        _formatError(SignalErrorCode.malformed),
      );
    });

    test('invalid JSON', () {
      expect(
        () => SignalMessage.decode('not json'),
        _formatError(SignalErrorCode.malformed),
      );
    });

    test('JSON that is not an object', () {
      expect(
        () => SignalMessage.decode('[1,2]'),
        _formatError(SignalErrorCode.malformed),
      );
    });

    test('missing required fields', () {
      for (final field in ['v', 'type', 'session', 'sender']) {
        expect(
          () => SignalMessage.decode(_json({}, remove: [field])),
          _formatError(SignalErrorCode.malformed),
          reason: 'missing $field',
        );
      }
    });

    test('empty sender and oversized ids', () {
      expect(
        () => SignalMessage.decode(_json({'sender': ''})),
        _formatError(SignalErrorCode.malformed),
      );
      expect(
        () => SignalMessage.decode(
          _json({'sender': 'x' * (kMaxSignalIdChars + 1)}),
        ),
        _formatError(SignalErrorCode.malformed),
      );
    });

    test('unknown message type', () {
      expect(
        () => SignalMessage.decode(_json({'type': 'run_command'})),
        _formatError(SignalErrorCode.malformed),
      );
    });

    test('payload that is not an object', () {
      expect(
        () => SignalMessage.decode(_json({'payload': 'text'})),
        _formatError(SignalErrorCode.malformed),
      );
    });

    test('too large message', () {
      final big = _json({
        'payload': <String, Object?>{'text': 'x' * kMaxSignalMessageChars},
      });
      expect(
        () => SignalMessage.decode(big),
        _formatError(SignalErrorCode.tooLarge),
      );
    });

    test('protocol version mismatch', () {
      expect(
        () => SignalMessage.decode(_json({'v': kSignalProtocolVersion + 1})),
        _formatError(SignalErrorCode.protocolMismatch),
      );
      expect(
        () => SignalMessage.decode(_json({'v': '1'})),
        _formatError(SignalErrorCode.malformed),
      );
    });
  });
}

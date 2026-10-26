import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/call_signal.dart';
import '../models/connection_validators.dart';
import '../models/handshake_auth.dart';
import '../models/session_tokens.dart';
import '../models/signal_message.dart';
import 'network_discovery_service.dart';

enum SignalRole { host, client }

enum SignalPhase {
  idle,
  starting,
  listening,
  connecting,
  handshaking,
  connected,
  disconnected,
  error,
}

enum LogKind { system, sent, received }

class SignalLogEntry {
  const SignalLogEntry({
    required this.time,
    required this.kind,
    required this.text,
  });

  final DateTime time;
  final LogKind kind;
  final String text;
}

class _JoinTarget {
  const _JoinTarget(this.host, this.port, this.pairingCode, this.sessionSecret);

  final String host;
  final int port;

  /// The typed 6-digit code, or empty when joining with the QR secret.
  final String pairingCode;

  /// The QR session secret, or null when joining with the typed code.
  /// Kept in memory only; never logged or stored.
  final String? sessionSecret;
}

enum _HostStage { awaitHello, awaitProof }

enum _ClientStage { awaitChallenge, awaitAck }

/// Local WebSocket signaling over a Wi-Fi hotspot, no internet involved.
///
/// One instance plays either the host (HTTP server upgraded to WebSocket,
/// one peer at a time) or the client. It exchanges test messages and
/// ping/pong, and (Phase 3) forwards authenticated call-negotiation messages
/// (offer, answer, candidate, call_ready, call_reject, call_end) to whoever
/// listens on [callMessages]. It does not touch WebRTC itself.
class LocalSignalService extends ChangeNotifier {
  LocalSignalService({
    NetworkDiscoveryService discovery = const NetworkDiscoveryService(),
    this.connectTimeout = const Duration(seconds: 6),
    this.handshakeTimeout = const Duration(seconds: 5),
    this.appPingInterval = const Duration(seconds: 5),
  }) : _discovery = discovery;

  static const String signalPath = '/signal';
  static const int defaultPort = 8080;
  static const int _maxFailedPairingAttempts = 5;
  static const int _maxLogEntries = 200;
  static const Duration _socketPingInterval = Duration(seconds: 5);
  static const Duration _closeWait = Duration(seconds: 2);

  final NetworkDiscoveryService _discovery;
  final Duration connectTimeout;
  final Duration handshakeTimeout;
  final Duration appPingInterval;

  final String _senderId = generateId();
  final List<SignalLogEntry> _log = <SignalLogEntry>[];
  final StreamController<SignalMessage> _callMessages =
      StreamController<SignalMessage>.broadcast();

  SignalRole? _role;
  SignalPhase _phase = SignalPhase.idle;
  String? _detail;
  bool _disposed = false;

  // Incremented whenever pending async work must be ignored.
  int _run = 0;
  // Incremented whenever the current socket is replaced or dropped.
  int _socketGen = 0;

  HttpServer? _server;
  StreamSubscription<HttpRequest>? _serverSub;
  WebSocket? _socket;
  StreamSubscription<dynamic>? _socketSub;
  Timer? _handshakeTimer;
  Timer? _pingTimer;

  String? _pairingCode;
  String? _sessionSecret;
  String? _sessionId;
  String? _peerSenderId;
  String? _peerAddress;
  int? _listeningPort;
  int _failedPairingAttempts = 0;
  int? _lastRttMs;
  List<LocalAddress> _addresses = const <LocalAddress>[];
  String? _addressError;
  _JoinTarget? _lastJoin;
  int _attempt = 0;
  bool _wasPaused = false;

  // Handshake state of the current socket (cleared when the socket goes).
  _HostStage _hostStage = _HostStage.awaitHello;
  _ClientStage _clientStage = _ClientStage.awaitChallenge;
  CredentialMode? _hsMode;
  String? _hsClientNonce;
  String? _hsHostNonce;
  String? _hsClientId;
  String? _hsHostId;

  SignalRole? get role => _role;
  SignalPhase get phase => _phase;
  String? get pairingCode => _pairingCode;

  /// The host's QR session secret. Only the host screen should display it
  /// (as a QR code); never log or store it.
  String? get sessionSecret => _role == SignalRole.host ? _sessionSecret : null;
  String? get sessionId => _sessionId;
  String? get peerAddress => _peerAddress;
  int? get listeningPort => _listeningPort;
  int? get lastRttMs => _lastRttMs;
  List<LocalAddress> get addresses => _addresses;
  String? get addressError => _addressError;
  List<SignalLogEntry> get log => List<SignalLogEntry>.unmodifiable(_log);
  bool get isConnected => _phase == SignalPhase.connected;
  bool get canRetry => _role == SignalRole.client && _lastJoin != null;

  /// Authenticated call-negotiation messages from the connected peer.
  ///
  /// Only messages with the right session id and sender id are delivered.
  /// Events are not buffered: listen before the call starts.
  Stream<SignalMessage> get callMessages => _callMessages.stream;

  bool get isHostRunning =>
      _role == SignalRole.host &&
      (_phase == SignalPhase.listening ||
          _phase == SignalPhase.handshaking ||
          _phase == SignalPhase.connected);

  /// Short human-readable status for the UI.
  String get statusText {
    final detail = _detail;
    if (detail != null) return detail;
    switch (_phase) {
      case SignalPhase.idle:
        return 'Not connected.';
      case SignalPhase.starting:
        return 'Starting host\u2026';
      case SignalPhase.listening:
        return 'Host is waiting for a phone to join.';
      case SignalPhase.connecting:
        return 'Connecting\u2026';
      case SignalPhase.handshaking:
        return 'Verifying pairing code\u2026';
      case SignalPhase.connected:
        return 'Connected to the other phone (signaling only; this is not '
            'the video call itself).';
      case SignalPhase.disconnected:
        return 'Disconnected.';
      case SignalPhase.error:
        return 'Something went wrong.';
    }
  }

  // ---------------------------------------------------------------- host --

  Future<void> startHost({int port = defaultPort}) async {
    if (_disposed || !_canStartNewSession) return;
    final run = ++_run;
    _beginSession(SignalRole.host);
    _pairingCode = generatePairingCode();
    _sessionSecret = generateSessionSecret();
    _sessionId = generateId();
    _failedPairingAttempts = 0;
    _setPhase(SignalPhase.starting, 'Starting host\u2026');
    await _teardown();
    if (run != _run) return;

    try {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      if (run != _run) {
        await server.close(force: true);
        return;
      }
      _server = server;
      _listeningPort = server.port;
      _serverSub = server.listen(
        (request) => unawaited(_handleRequest(request, run)),
        onError: (Object error) {
          debugPrint('Server error: ${error.runtimeType}');
        },
        onDone: () {
          if (run == _run && _role == SignalRole.host) {
            unawaited(_fail('The host server stopped unexpectedly.'));
          }
        },
      );
      await refreshAddresses();
      if (run != _run) return;
      _addLog(LogKind.system, 'Host started on port $_listeningPort.');
      _setPhase(SignalPhase.listening, null);
    } on SocketException catch (error) {
      if (run != _run) return;
      await _fail(_describeBindError(error, port));
    } catch (error) {
      debugPrint('Starting host failed: ${error.runtimeType}');
      if (run != _run) return;
      final description = error.toString().toLowerCase();
      if (description.contains('address already in use') ||
          description.contains('already in use') ||
          description.contains('eaddrinuse')) {
        await _fail(
          'Port $port is already in use. Choose another port or close '
          'the other app.',
        );
      } else if (description.contains('permission denied') ||
          description.contains('eacces')) {
        await _fail(
          'Android did not allow opening port $port. Try a port above '
          '1024.',
        );
      } else {
        await _fail('Could not start the host on port $port.');
      }
    }
  }

  Future<void> refreshAddresses() async {
    final run = _run;
    final result = await _discovery.listLocalAddresses();
    if (_disposed || run != _run) return;
    _addresses = result.addresses;
    _addressError = result.errorMessage;
    _notify();
  }

  Future<void> _handleRequest(HttpRequest request, int run) async {
    try {
      if (run != _run ||
          request.uri.path != signalPath ||
          !WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final remote = request.connectionInfo?.remoteAddress.address;
      // A browser always sends an Origin header; this app never does. This
      // blocks web pages in a browser on the hotspot from probing the host.
      if (request.headers.value('origin') != null) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        _addLog(LogKind.system, 'Refused a browser-style request.');
        return;
      }
      // The host listens on every interface, so refuse anything that is not
      // a local-network (or this phone's own) address, for example a
      // mobile-data address.
      if (!isAllowedPeerAddress(remote)) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        _addLog(
          LogKind.system,
          'Refused a connection from outside the '
          'local network.',
        );
        return;
      }
      final socket = await WebSocketTransformer.upgrade(
        request,
        compression: CompressionOptions.compressionOff,
      );
      if (run != _run) {
        unawaited(_closeQuietly(socket));
        return;
      }
      if (_socket != null) {
        _rejectExtraClient(socket);
        return;
      }
      _attachSocket(socket, remote: remote);
    } catch (error) {
      debugPrint('Handling request failed: ${error.runtimeType}');
    }
  }

  void _rejectExtraClient(WebSocket socket) {
    try {
      socket.add(
        SignalMessage.error(
          senderId: _senderId,
          code: SignalErrorCode.hostBusy,
          message: 'This host already has a connected phone.',
        ).encode(),
      );
    } catch (_) {
      // The extra client is closed below either way.
    }
    unawaited(_closeQuietly(socket));
    _addLog(LogKind.system, 'Rejected a second phone: host is busy.');
  }

  // -------------------------------------------------------------- client --

  /// Joins a host with either the typed 6-digit [pairingCode] or the QR
  /// [sessionSecret] (preferred: it is 128 bits and is never sent, only
  /// proven with a MAC).
  Future<void> join({
    required String host,
    required int port,
    String pairingCode = '',
    String? sessionSecret,
  }) async {
    if (_disposed || !_canStartNewSession) return;
    final problem =
        validateIPv4Address(host) ?? validatePortNumber(port.toString());
    if (problem != null) {
      _role = SignalRole.client;
      _setPhase(SignalPhase.error, problem);
      return;
    }
    final useSecret = sessionSecret != null;
    final codeProblem = useSecret
        ? (isValidSessionSecret(sessionSecret)
              ? null
              : 'The QR credential is not valid. Scan the QR code again.')
        : validatePairingCode(pairingCode);
    if (codeProblem != null) {
      _role = SignalRole.client;
      _setPhase(SignalPhase.error, codeProblem);
      return;
    }
    _lastJoin = _JoinTarget(
      host.trim(),
      port,
      useSecret ? '' : pairingCode.trim(),
      useSecret ? sessionSecret : null,
    );
    _attempt = 0;
    await _connect(clearLog: true);
  }

  /// User-triggered reconnect with the last host, port and code.
  Future<void> retry() async {
    if (_disposed || _lastJoin == null || !_canStartNewSession) return;
    await _connect(clearLog: false);
  }

  Future<void> _connect({required bool clearLog}) async {
    final target = _lastJoin;
    if (target == null) return;
    final run = ++_run;
    _beginSession(SignalRole.client, clearLog: clearLog);
    _attempt++;
    _pairingCode = target.pairingCode.isEmpty ? null : target.pairingCode;
    _sessionId = null;
    _setPhase(
      SignalPhase.connecting,
      'Connecting to ${target.host}:${target.port} (attempt $_attempt)\u2026',
    );
    await _teardown();
    if (run != _run) return;

    final url = 'ws://${target.host}:${target.port}$signalPath';
    final future = WebSocket.connect(
      url,
      compression: CompressionOptions.compressionOff,
    );
    final WebSocket socket;
    try {
      socket = await future.timeout(connectTimeout);
    } on TimeoutException {
      // A late successful connection must not leak.
      unawaited(
        future.then<void>(
          (lateSocket) => unawaited(_closeQuietly(lateSocket)),
          onError: (Object _) {},
        ),
      );
      if (run != _run) return;
      await _fail(
        'Connection timed out. Check that both phones use the same hotspot '
        'and that the host is running.',
      );
      return;
    } catch (error) {
      if (run != _run) return;
      await _fail(_describeConnectError(error));
      return;
    }

    if (run != _run) {
      unawaited(_closeQuietly(socket));
      return;
    }
    _attachSocket(socket, remote: target.host);
    // The credential itself is never sent. The first message only names
    // which credential will be proven and carries a fresh random nonce.
    final mode = target.sessionSecret != null
        ? CredentialMode.secret
        : CredentialMode.code;
    _hsMode = mode;
    _hsClientNonce = generateNonce();
    _clientStage = _ClientStage.awaitChallenge;
    _send(
      SignalMessage(
        type: SignalType.hello,
        sessionId: '',
        senderId: _senderId,
        payload: <String, Object?>{'mode': mode.wireName, 'cn': _hsClientNonce},
      ),
    );
  }

  // --------------------------------------------------------- both roles ---

  Future<void> stop() async {
    if (_disposed) return;
    _run++;
    final hadSession = _role != null && _phase != SignalPhase.idle;
    final wasHost = _role == SignalRole.host;
    await _teardown();
    if (_disposed) return;
    if (wasHost) {
      _pairingCode = null;
      _sessionSecret = null;
    }
    if (hadSession) {
      _addLog(LogKind.system, wasHost ? 'Host stopped.' : 'Disconnected.');
    }
    _setPhase(SignalPhase.idle, null);
  }

  void sendChat(String text) {
    final value = text.trim();
    if (_phase != SignalPhase.connected || value.isEmpty) return;
    if (value.length > kMaxChatChars) {
      _addLog(LogKind.system, 'Message is too long (max $kMaxChatChars).');
      return;
    }
    if (_send(_connectedMessage(SignalType.chat, {'text': value}))) {
      _addLog(LogKind.sent, value);
    }
  }

  void sendPing() {
    if (_phase != SignalPhase.connected) return;
    _send(
      _connectedMessage(SignalType.ping, <String, Object?>{
        't': DateTime.now().microsecondsSinceEpoch,
      }),
    );
  }

  /// Sends one call-negotiation message to the connected peer.
  ///
  /// Never logs the payload: SDP and ICE candidates contain private network
  /// addresses.
  CallSendResult sendCall(SignalType type, Map<String, Object?> payload) {
    // `error` is allowed so a refused call message can be answered.
    if (!isCallSignal(type) && type != SignalType.error) {
      return CallSendResult.notACallMessage;
    }
    if (_phase != SignalPhase.connected) return CallSendResult.notConnected;
    final message = _connectedMessage(type, payload);
    final encoded = message.encode();
    if (encoded.length > kMaxSignalMessageChars) {
      _addLog(
        LogKind.system,
        'A ${type.wireName} message was too large to send.',
      );
      return CallSendResult.tooLarge;
    }
    final socket = _socket;
    if (socket == null) return CallSendResult.notConnected;
    try {
      socket.add(encoded);
      return CallSendResult.sent;
    } catch (error) {
      debugPrint('Call send failed: ${error.runtimeType}');
      return CallSendResult.notConnected;
    }
  }

  void onAppPaused() {
    if (_role == null || _phase == SignalPhase.idle) return;
    _wasPaused = true;
    _addLog(
      LogKind.system,
      'App went to the background. The connection may be interrupted '
      'while the app is not on screen.',
    );
  }

  void onAppResumed() {
    if (!_wasPaused) return;
    _wasPaused = false;
    _addLog(LogKind.system, 'App is active again.');
    if (_phase == SignalPhase.connected) {
      sendPing();
    } else if (_phase == SignalPhase.listening) {
      unawaited(refreshAddresses());
    }
  }

  // ---------------------------------------------------------- internals ---

  bool get _canStartNewSession =>
      _phase == SignalPhase.idle ||
      _phase == SignalPhase.error ||
      _phase == SignalPhase.disconnected;

  void _beginSession(SignalRole role, {bool clearLog = true}) {
    _role = role;
    if (clearLog) _log.clear();
    _lastRttMs = null;
    _peerAddress = null;
    _peerSenderId = null;
    _detail = null;
  }

  SignalMessage _connectedMessage(
    SignalType type,
    Map<String, Object?> payload,
  ) {
    return SignalMessage(
      type: type,
      sessionId: _sessionId ?? '',
      senderId: _senderId,
      payload: payload,
    );
  }

  void _attachSocket(WebSocket socket, {String? remote}) {
    final gen = ++_socketGen;
    _socket = socket;
    _peerAddress = remote;
    socket.pingInterval = _socketPingInterval;
    _socketSub = socket.listen(
      (Object? data) => _onData(data, gen),
      onError: (Object error) {
        debugPrint('Socket error: ${error.runtimeType}');
        _onPeerGone(gen);
      },
      onDone: () => _onPeerGone(gen),
      cancelOnError: true,
    );
    _handshakeTimer = Timer(handshakeTimeout, () => _onHandshakeTimeout(gen));
    _setPhase(
      SignalPhase.handshaking,
      _role == SignalRole.host
          ? 'A phone connected from ${remote ?? 'unknown address'}. '
                'Verifying pairing code\u2026'
          : 'Reached the host. Verifying pairing code\u2026',
    );
  }

  void _onData(Object? data, int gen) {
    if (gen != _socketGen || _disposed) return;
    final SignalMessage message;
    try {
      message = SignalMessage.decode(data);
    } on SignalFormatException catch (error) {
      _onInvalidMessage(error);
      return;
    }
    if (_phase == SignalPhase.handshaking) {
      if (_role == SignalRole.host) {
        _hostHandshake(message);
      } else {
        _clientHandshake(message);
      }
    } else if (_phase == SignalPhase.connected) {
      _handleConnectedMessage(message);
    }
  }

  void _onInvalidMessage(SignalFormatException error) {
    final fatal =
        _phase == SignalPhase.handshaking ||
        error.code == SignalErrorCode.tooLarge ||
        error.code == SignalErrorCode.protocolMismatch;
    _send(
      SignalMessage.error(
        senderId: _senderId,
        code: error.code,
        message: error.message,
        sessionId: _phase == SignalPhase.connected ? _sessionId ?? '' : '',
      ),
    );
    if (!fatal) {
      _addLog(LogKind.system, 'Ignored an invalid message (${error.code}).');
      return;
    }
    _dropPeer(
      detail: error.code == SignalErrorCode.protocolMismatch
          ? 'The other phone uses a different protocol version. '
                'Install the same app version on both phones.'
          : 'Received an invalid message (${error.code}). Connection closed.',
      isError: _role == SignalRole.client,
    );
  }

  void _hostHandshake(SignalMessage message) {
    switch (_hostStage) {
      case _HostStage.awaitHello:
        _hostOnHello(message);
      case _HostStage.awaitProof:
        _hostOnProof(message);
    }
  }

  void _hostOnHello(SignalMessage message) {
    if (message.type != SignalType.hello) {
      _rejectPeer(
        code: SignalErrorCode.unexpectedMessage,
        detail: 'A phone sent an unexpected message and was disconnected.',
      );
      return;
    }
    final mode = CredentialMode.fromWireName(message.payload['mode']);
    final clientNonce = message.payload['cn'];
    if (mode == null || !isValidNonce(clientNonce)) {
      _rejectPeer(
        code: SignalErrorCode.malformed,
        detail:
            'A phone sent a malformed join request and was '
            'disconnected.',
      );
      return;
    }
    _hsMode = mode;
    _hsClientNonce = clientNonce as String;
    _hsClientId = message.senderId;
    _hsHostId = _senderId;
    _hsHostNonce = generateNonce();
    _hostStage = _HostStage.awaitProof;
    _send(
      SignalMessage(
        type: SignalType.helloChallenge,
        sessionId: _sessionId ?? '',
        senderId: _senderId,
        payload: <String, Object?>{'sn': _hsHostNonce},
      ),
    );
  }

  void _hostOnProof(SignalMessage message) {
    final mode = _hsMode;
    final clientNonce = _hsClientNonce;
    final hostNonce = _hsHostNonce;
    final clientId = _hsClientId;
    final sessionId = _sessionId;
    final credential = mode == CredentialMode.secret
        ? _sessionSecret
        : _pairingCode;
    if (message.type != SignalType.helloProof ||
        mode == null ||
        clientNonce == null ||
        hostNonce == null ||
        clientId == null ||
        sessionId == null ||
        credential == null ||
        message.senderId != clientId ||
        message.sessionId != sessionId) {
      _rejectPeer(
        code: SignalErrorCode.unexpectedMessage,
        detail: 'A phone sent an unexpected message and was disconnected.',
      );
      return;
    }
    final proof = message.payload['mac'];
    final key = credentialKey(mode, credential);
    final expected = handshakeMac(
      key: key,
      label: kClientProofLabel,
      clientNonce: clientNonce,
      hostNonce: hostNonce,
      clientId: clientId,
      hostId: _senderId,
      sessionId: sessionId,
    );
    if (!isValidMac(proof) || !constantTimeEquals(expected, proof as String)) {
      _failedPairingAttempts++;
      _rejectPeer(
        code: SignalErrorCode.badPairingCode,
        detail: 'A phone tried to join with a wrong pairing credential.',
      );
      if (_failedPairingAttempts >= _maxFailedPairingAttempts) {
        unawaited(
          _fail(
            'Too many failed pairing attempts. The host was stopped. '
            'Start it again to get new credentials.',
          ),
        );
      }
      return;
    }
    _handshakeTimer?.cancel();
    _handshakeTimer = null;
    _peerSenderId = clientId;
    // Prove to the joining phone that this host knows the credential too.
    final hostProof = handshakeMac(
      key: key,
      label: kHostProofLabel,
      clientNonce: clientNonce,
      hostNonce: hostNonce,
      clientId: clientId,
      hostId: _senderId,
      sessionId: sessionId,
    );
    _send(
      SignalMessage(
        type: SignalType.helloAck,
        sessionId: sessionId,
        senderId: _senderId,
        payload: <String, Object?>{'accepted': true, 'mac': hostProof},
      ),
    );
    _clearHandshakeState();
    _onConnected('Phone connected from ${_peerAddress ?? 'unknown address'}.');
  }

  void _clientHandshake(SignalMessage message) {
    if (message.type == SignalType.error) {
      _dropPeer(detail: _describeRemoteError(message), isError: true);
      return;
    }
    switch (_clientStage) {
      case _ClientStage.awaitChallenge:
        _clientOnChallenge(message);
      case _ClientStage.awaitAck:
        _clientOnAck(message);
    }
  }

  void _clientOnChallenge(SignalMessage message) {
    final hostNonce = message.payload['sn'];
    final target = _lastJoin;
    final mode = _hsMode;
    final clientNonce = _hsClientNonce;
    if (message.type != SignalType.helloChallenge ||
        !isValidNonce(hostNonce) ||
        message.sessionId.isEmpty ||
        target == null ||
        mode == null ||
        clientNonce == null) {
      _dropPeer(
        detail: 'The host sent an unexpected reply. Is it running this app?',
        isError: true,
      );
      return;
    }
    final credential = mode == CredentialMode.secret
        ? target.sessionSecret
        : target.pairingCode;
    if (credential == null || credential.isEmpty) {
      _dropPeer(detail: 'No pairing credential to use.', isError: true);
      return;
    }
    final challengeNonce = hostNonce as String;
    _hsHostNonce = challengeNonce;
    _hsHostId = message.senderId;
    _sessionId = message.sessionId;
    final proof = handshakeMac(
      key: credentialKey(mode, credential),
      label: kClientProofLabel,
      clientNonce: clientNonce,
      hostNonce: challengeNonce,
      clientId: _senderId,
      hostId: message.senderId,
      sessionId: message.sessionId,
    );
    _clientStage = _ClientStage.awaitAck;
    _send(
      SignalMessage(
        type: SignalType.helloProof,
        sessionId: message.sessionId,
        senderId: _senderId,
        payload: <String, Object?>{'mac': proof},
      ),
    );
  }

  void _clientOnAck(SignalMessage message) {
    final target = _lastJoin;
    final mode = _hsMode;
    final clientNonce = _hsClientNonce;
    final hostNonce = _hsHostNonce;
    final hostId = _hsHostId;
    final sessionId = _sessionId;
    if (message.type != SignalType.helloAck ||
        message.payload['accepted'] != true ||
        target == null ||
        mode == null ||
        clientNonce == null ||
        hostNonce == null ||
        hostId == null ||
        sessionId == null ||
        message.sessionId != sessionId ||
        message.senderId != hostId) {
      _dropPeer(
        detail: 'The host sent an unexpected reply. Is it running this app?',
        isError: true,
      );
      return;
    }
    final credential = mode == CredentialMode.secret
        ? target.sessionSecret
        : target.pairingCode;
    final expected = handshakeMac(
      key: credentialKey(mode, credential ?? ''),
      label: kHostProofLabel,
      clientNonce: clientNonce,
      hostNonce: hostNonce,
      clientId: _senderId,
      hostId: hostId,
      sessionId: sessionId,
    );
    final proof = message.payload['mac'];
    if (!isValidMac(proof) || !constantTimeEquals(expected, proof as String)) {
      // Whoever answered did not know the credential: do not trust it.
      _dropPeer(
        detail:
            'The phone that answered could not prove it knows the '
            'pairing credential, so the connection was refused.',
        isError: true,
      );
      return;
    }
    _handshakeTimer?.cancel();
    _handshakeTimer = null;
    _peerSenderId = hostId;
    _clearHandshakeState();
    _onConnected('Connected to the host at ${_peerAddress ?? 'its address'}.');
  }

  void _clearHandshakeState() {
    _hostStage = _HostStage.awaitHello;
    _clientStage = _ClientStage.awaitChallenge;
    _hsMode = null;
    _hsClientNonce = null;
    _hsHostNonce = null;
    _hsClientId = null;
    _hsHostId = null;
  }

  void _onConnected(String text) {
    _addLog(LogKind.system, text);
    _setPhase(SignalPhase.connected, null);
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(appPingInterval, (_) => sendPing());
    sendPing();
  }

  void _handleConnectedMessage(SignalMessage message) {
    if (message.sessionId != _sessionId || message.senderId != _peerSenderId) {
      _send(
        _connectedMessage(SignalType.error, <String, Object?>{
          'code': SignalErrorCode.sessionMismatch,
          'message': 'Wrong session or sender.',
        }),
      );
      _addLog(LogKind.system, 'Ignored a message from a different session.');
      return;
    }
    switch (message.type) {
      case SignalType.ping:
        _send(_connectedMessage(SignalType.pong, message.payload));
      case SignalType.pong:
        final sentAt = message.payload['t'];
        if (sentAt is num) {
          final elapsedUs =
              DateTime.now().microsecondsSinceEpoch - sentAt.toInt();
          if (elapsedUs >= 0) {
            _lastRttMs = (elapsedUs / 1000).round();
            _notify();
          }
        }
      case SignalType.chat:
        final text = message.payload['text'];
        if (text is String && text.isNotEmpty && text.length <= kMaxChatChars) {
          _addLog(LogKind.received, text);
        } else {
          _send(
            _connectedMessage(SignalType.error, <String, Object?>{
              'code': SignalErrorCode.malformed,
              'message': 'Invalid chat message.',
            }),
          );
        }
      case SignalType.error:
        final code = message.payload['code'];
        _addLog(
          LogKind.system,
          'The other phone reported an error'
          '${code is String ? ' ($code)' : ''}.',
        );
      case SignalType.hello:
      case SignalType.helloChallenge:
      case SignalType.helloProof:
      case SignalType.helloAck:
        _send(
          _connectedMessage(SignalType.error, <String, Object?>{
            'code': SignalErrorCode.unexpectedMessage,
            'message': 'Handshake is already done.',
          }),
        );
      case SignalType.offer:
      case SignalType.answer:
      case SignalType.candidate:
      case SignalType.callReady:
      case SignalType.callReject:
      case SignalType.callEnd:
        if (!_callMessages.isClosed) _callMessages.add(message);
    }
  }

  void _onHandshakeTimeout(int gen) {
    if (gen != _socketGen || _phase != SignalPhase.handshaking) return;
    if (_role == SignalRole.host) {
      _rejectPeer(
        code: SignalErrorCode.handshakeTimeout,
        detail: 'A phone connected but did not finish the handshake in time.',
      );
    } else {
      _dropPeer(
        detail: 'The host did not answer. Is it running this app on this port?',
        isError: true,
      );
    }
  }

  void _onPeerGone(int gen) {
    if (gen != _socketGen || _disposed) return;
    final wasConnected = _phase == SignalPhase.connected;
    final isHost = _role == SignalRole.host;
    if (isHost) {
      _dropPeer(
        detail: wasConnected
            ? 'The phone disconnected. Waiting for a new connection.'
            : 'The phone left before finishing the handshake.',
      );
    } else if (wasConnected) {
      _dropPeer(detail: 'Connection lost. Tap Retry to reconnect.');
    } else {
      _dropPeer(
        detail: 'The host closed the connection during the handshake.',
        isError: true,
      );
    }
  }

  void _rejectPeer({required String code, required String detail}) {
    _send(
      SignalMessage.error(
        senderId: _senderId,
        code: code,
        message: _remoteErrorText(code),
      ),
    );
    _dropPeer(detail: detail);
  }

  /// Closes the current peer socket and moves to the right resting phase.
  void _dropPeer({required String detail, bool isError = false}) {
    _closeCurrentSocket();
    _addLog(LogKind.system, detail);
    if (_role == SignalRole.host) {
      _setPhase(
        _server != null ? SignalPhase.listening : SignalPhase.idle,
        detail,
      );
    } else {
      _setPhase(isError ? SignalPhase.error : SignalPhase.disconnected, detail);
    }
  }

  bool _send(SignalMessage message) {
    final socket = _socket;
    if (socket == null) return false;
    try {
      socket.add(message.encode());
      return true;
    } catch (error) {
      debugPrint('Send failed: ${error.runtimeType}');
      return false;
    }
  }

  /// Stops timers, ignores the socket's future events and closes it.
  void _closeCurrentSocket() {
    _handshakeTimer?.cancel();
    _handshakeTimer = null;
    _pingTimer?.cancel();
    _pingTimer = null;
    _socketGen++;
    _clearHandshakeState();
    final socket = _socket;
    final subscription = _socketSub;
    _socket = null;
    _socketSub = null;
    _peerAddress = null;
    _peerSenderId = null;
    _lastRttMs = null;
    if (socket != null) unawaited(_closeQuietly(socket));
    if (subscription != null) unawaited(subscription.cancel());
  }

  Future<void> _closeQuietly(WebSocket socket) async {
    try {
      await socket
          .close(WebSocketStatus.normalClosure, 'closed')
          .timeout(_closeWait);
    } catch (_) {
      // Closing is best effort; the socket cleans itself up.
    }
  }

  /// Releases the server and any peer socket. Does not notify listeners.
  Future<void> _teardown() async {
    _closeCurrentSocket();
    final serverSub = _serverSub;
    final server = _server;
    _serverSub = null;
    _server = null;
    _listeningPort = null;
    await serverSub?.cancel();
    if (server != null) {
      try {
        await server.close(force: true);
      } catch (error) {
        debugPrint('Closing server failed: ${error.runtimeType}');
      }
    }
  }

  Future<void> _fail(String message) async {
    await _teardown();
    if (_disposed) return;
    if (_role == SignalRole.host) {
      _pairingCode = null;
      _sessionSecret = null;
    }
    _addLog(LogKind.system, message);
    _setPhase(SignalPhase.error, message);
  }

  void _setPhase(SignalPhase phase, String? detail) {
    _phase = phase;
    _detail = detail;
    _notify();
  }

  void _addLog(LogKind kind, String text) {
    _log.add(SignalLogEntry(time: DateTime.now(), kind: kind, text: text));
    if (_log.length > _maxLogEntries) {
      _log.removeRange(0, _log.length - _maxLogEntries);
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  String _describeBindError(SocketException error, int port) {
    final code = error.osError?.errorCode;
    final text = '${error.message} ${error.osError?.message ?? ''}'
        .toLowerCase();
    if (code == 98 || text.contains('already in use')) {
      return 'Port $port is already in use. Choose another port or close '
          'the other app.';
    }
    if (code == 13 || text.contains('permission denied')) {
      return 'Android did not allow opening port $port. Try a port above '
          '1024.';
    }
    return 'Could not start the host on port $port.';
  }

  String _describeConnectError(Object error) {
    if (error is SocketException) {
      final code = error.osError?.errorCode;
      final text = '${error.message} ${error.osError?.message ?? ''}'
          .toLowerCase();
      if (code == 111 || text.contains('refused')) {
        return 'Connection refused. The host is not running on this port, '
            'or the port is wrong.';
      }
      if (code == 113 || code == 101 || text.contains('unreachable')) {
        return 'Host unreachable. Check that both phones are on the same '
            'hotspot and the IP address is right.';
      }
      if (code == 110 || text.contains('timed out')) {
        return 'Connection timed out. Check the IP address and the hotspot.';
      }
      return 'Could not reach the host. Check the IP address, port and '
          'hotspot.';
    }
    if (error is WebSocketException) {
      return 'A device answered, but it is not an Offline Video Call host '
          'at this address and port.';
    }
    return 'Could not connect to the host.';
  }

  String _describeRemoteError(SignalMessage message) {
    final code = message.payload['code'];
    return _remoteErrorText(code is String ? code : '');
  }

  String _remoteErrorText(String code) {
    switch (code) {
      case SignalErrorCode.badPairingCode:
        return 'Wrong pairing code or QR code. Check the code shown on the '
            'host, or scan the QR code again.';
      case SignalErrorCode.hostBusy:
        return 'The host already has a connected phone.';
      case SignalErrorCode.protocolMismatch:
        return 'The other phone uses a different protocol version. '
            'Install the same app version on both phones.';
      case SignalErrorCode.handshakeTimeout:
        return 'The host closed the connection because the handshake took '
            'too long.';
      case SignalErrorCode.unexpectedMessage:
        return 'The host did not understand the request.';
      default:
        return 'The host refused the connection.';
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _run++;
    unawaited(_teardown());
    unawaited(_callMessages.close());
    super.dispose();
  }
}

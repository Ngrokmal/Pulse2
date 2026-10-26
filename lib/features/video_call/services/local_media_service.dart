import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';

enum LocalMediaStatus {
  idle,
  starting,
  ready,
  permissionDenied,
  permissionPermanentlyDenied,
  noCamera,
  error,
}

/// Owns the local camera/microphone stream and its renderer.
///
/// The UI only listens to this object and calls its methods; all resource
/// handling (permissions, stream, renderer, cleanup) lives here.
class LocalMediaService extends ChangeNotifier {
  /// Capture settings default to 720p / 30 fps. The camera may deliver less;
  /// check the real values in the call statistics.
  LocalMediaService({
    this.videoWidth = 1280,
    this.videoHeight = 720,
    this.videoFrameRate = 30,
  });

  static const String _videoInputKind = 'videoinput';

  final int videoWidth;
  final int videoHeight;
  final int videoFrameRate;

  final RTCVideoRenderer renderer = RTCVideoRenderer();

  MediaStream? _stream;
  Future<void>? _startTask;
  bool _rendererInitialized = false;
  bool _disposed = false;

  LocalMediaStatus _status = LocalMediaStatus.idle;
  String? _message;
  String? _warning;
  bool _micEnabled = true;
  bool _cameraEnabled = true;
  bool _isFrontCamera = true;
  bool _canSwitchCamera = false;
  bool _isSwitchingCamera = false;

  /// The live camera/microphone stream while [isReady]. It stays owned by
  /// this service: other code may add its tracks to a peer connection but
  /// must not stop or dispose it.
  MediaStream? get stream => isReady ? _stream : null;

  LocalMediaStatus get status => _status;
  bool get isReady => _status == LocalMediaStatus.ready;
  bool get hasProblem =>
      _status == LocalMediaStatus.permissionDenied ||
      _status == LocalMediaStatus.permissionPermanentlyDenied ||
      _status == LocalMediaStatus.noCamera ||
      _status == LocalMediaStatus.error;

  /// User-facing explanation when [hasProblem] is true.
  String? get message => _message;

  /// Non-fatal problem, e.g. the camera could not be switched.
  String? get warning => _warning;

  bool get micEnabled => _micEnabled;
  bool get cameraEnabled => _cameraEnabled;
  bool get isFrontCamera => _isFrontCamera;
  bool get canSwitchCamera => _canSwitchCamera;
  bool get isSwitchingCamera => _isSwitchingCamera;

  /// Requests permissions and starts the local stream.
  /// Safe to call repeatedly: a running or finished start is not repeated.
  Future<void> start() {
    if (_disposed) return Future<void>.value();
    final running = _startTask;
    if (running != null) return running;
    if (isReady) return Future<void>.value();

    final task = _start().whenComplete(() => _startTask = null);
    _startTask = task;
    return task;
  }

  Future<void> _start() async {
    _message = null;
    _warning = null;
    _setStatus(LocalMediaStatus.starting);
    try {
      final permissionProblem = await _requestPermissions();
      if (_disposed) return;
      if (permissionProblem != null) {
        _setStatus(permissionProblem);
        return;
      }

      if (!_rendererInitialized) {
        await renderer.initialize();
        _rendererInitialized = true;
      }
      if (_disposed) return;

      final devices = await navigator.mediaDevices.enumerateDevices();
      final cameraCount = devices
          .where((device) => device.kind == _videoInputKind)
          .length;
      if (cameraCount == 0) {
        _message = 'No camera was found on this device.';
        _setStatus(LocalMediaStatus.noCamera);
        return;
      }

      final stream = await navigator.mediaDevices.getUserMedia(
        <String, dynamic>{
          'audio': true,
          'video': <String, dynamic>{
            'facingMode': 'user',
            'width': videoWidth,
            'height': videoHeight,
            'frameRate': videoFrameRate,
          },
        },
      );
      if (_disposed) {
        await _stopStream(stream);
        return;
      }

      _stream = stream;
      renderer.srcObject = stream;
      _canSwitchCamera = cameraCount > 1;
      _isFrontCamera = true;
      _micEnabled = true;
      _cameraEnabled = true;
      _setStatus(LocalMediaStatus.ready);
    } catch (error, stackTrace) {
      debugPrint('Local media start failed: $error\n$stackTrace');
      await _releaseStream();
      _message =
          'Could not start the camera. Close other apps that use '
          'the camera or microphone, then try again.';
      _setStatus(LocalMediaStatus.error);
    }
  }

  /// Returns null when both permissions are granted, otherwise the status
  /// describing the problem (and sets [message]).
  Future<LocalMediaStatus?> _requestPermissions() async {
    final results = await <Permission>[
      Permission.camera,
      Permission.microphone,
    ].request();
    final camera = results[Permission.camera];
    final microphone = results[Permission.microphone];

    if (camera == PermissionStatus.granted &&
        microphone == PermissionStatus.granted) {
      return null;
    }
    final permanent =
        (camera?.isPermanentlyDenied ?? false) ||
        (microphone?.isPermanentlyDenied ?? false);
    if (permanent) {
      _message =
          'Camera or microphone permission was permanently denied. '
          'Open app settings and allow both permissions.';
      return LocalMediaStatus.permissionPermanentlyDenied;
    }
    _message =
        'Camera and microphone permissions are needed to show '
        'your local preview. Local video does not use the internet.';
    return LocalMediaStatus.permissionDenied;
  }

  void toggleMicrophone() {
    final stream = _stream;
    if (stream == null || !isReady) return;
    _micEnabled = !_micEnabled;
    for (final track in stream.getAudioTracks()) {
      track.enabled = _micEnabled;
    }
    _notify();
  }

  void toggleCamera() {
    final stream = _stream;
    if (stream == null || !isReady) return;
    _cameraEnabled = !_cameraEnabled;
    for (final track in stream.getVideoTracks()) {
      track.enabled = _cameraEnabled;
    }
    _notify();
  }

  Future<void> switchCamera() async {
    final stream = _stream;
    if (stream == null || !isReady || !_canSwitchCamera) return;
    if (_isSwitchingCamera) return;
    final tracks = stream.getVideoTracks();
    if (tracks.isEmpty) return;

    _isSwitchingCamera = true;
    _warning = null;
    _notify();
    try {
      await Helper.switchCamera(tracks.first);
      _isFrontCamera = !_isFrontCamera;
    } catch (error, stackTrace) {
      debugPrint('Camera switch failed: $error\n$stackTrace');
      _warning = 'Could not switch the camera.';
    } finally {
      _isSwitchingCamera = false;
      _notify();
    }
  }

  /// Releases the camera and microphone and returns to the idle state, so
  /// something else (the QR scanner) can use the camera. A later [start]
  /// opens the devices again. Safe to call at any time and repeatedly.
  Future<void> stop() async {
    if (_disposed) return;
    final running = _startTask;
    if (running != null) {
      try {
        await running;
      } catch (_) {
        // A failed start has already cleaned up after itself.
      }
    }
    if (_disposed) return;
    await _releaseStream();
    _micEnabled = true;
    _cameraEnabled = true;
    _isFrontCamera = true;
    _canSwitchCamera = false;
    _isSwitchingCamera = false;
    _message = null;
    _warning = null;
    _setStatus(LocalMediaStatus.idle);
  }

  Future<void> openSettings() async {
    await openAppSettings();
  }

  Future<void> _releaseStream() async {
    final stream = _stream;
    _stream = null;
    if (_rendererInitialized) {
      renderer.srcObject = null;
    }
    if (stream != null) {
      await _stopStream(stream);
    }
  }

  Future<void> _stopStream(MediaStream stream) async {
    try {
      for (final track in stream.getTracks()) {
        await track.stop();
      }
      await stream.dispose();
    } catch (error) {
      debugPrint('Stopping stream failed: $error');
    }
  }

  void _setStatus(LocalMediaStatus status) {
    _status = status;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_shutdown());
    super.dispose();
  }

  Future<void> _shutdown() async {
    try {
      await _startTask;
    } catch (_) {
      // A failed start has already cleaned up after itself.
    }
    await _releaseStream();
    try {
      await renderer.dispose();
    } catch (error) {
      debugPrint('Disposing renderer failed: $error');
    }
  }
}

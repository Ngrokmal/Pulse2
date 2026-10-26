import 'dart:async';

import 'package:flutter/material.dart';

import '../models/call_role.dart';
import '../models/call_state.dart';
import '../services/local_media_service.dart';
import '../services/local_signal_service.dart';
import '../services/webrtc_service.dart';
import 'widgets/call_controls.dart';
import 'widgets/call_status_panel.dart';
import 'widgets/connection_panel.dart';
import 'widgets/diagnostics_panel.dart';
import 'widgets/local_video_preview.dart';
import 'widgets/remote_video_view.dart';

class CallScreen extends StatefulWidget {
  const CallScreen({super.key, required this.role});

  final CallRole role;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> with WidgetsBindingObserver {
  static const int _connectionTab = 0;
  static const int _cameraTab = 1;

  late final LocalMediaService _media;
  late final LocalSignalService _signal;
  late final WebRtcService _webrtc;
  final ValueNotifier<bool> _showDiagnostics = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _callActive = ValueNotifier<bool>(false);
  int _tab = _connectionTab;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _media = LocalMediaService();
    _signal = LocalSignalService();
    // The Host creates the offer; the phone that joined answers.
    _webrtc = WebRtcService(
      signal: _signal,
      media: _media,
      role: widget.role == CallRole.host
          ? NegotiationRole.offerer
          : NegotiationRole.answerer,
    );
    _webrtc.addListener(_closeDiagnosticsWhenCallEnds);
  }

  void _closeDiagnosticsWhenCallEnds() {
    final active = _webrtc.isCallActive;
    // ValueNotifier only notifies when the value really changes.
    _callActive.value = active;
    if (!active && _showDiagnostics.value) {
      _showDiagnostics.value = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _webrtc.removeListener(_closeDiagnosticsWhenCallEnds);
    _showDiagnostics.dispose();
    _callActive.dispose();
    // Closes the peer connection and remote renderer first. It does not stop
    // the camera (media) or the signaling connection (signal).
    _webrtc.dispose();
    // Closes the server/socket and its timers and subscriptions.
    _signal.dispose();
    // Stops the camera/microphone tracks and disposes the renderer.
    _media.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _signal.onAppPaused();
      _webrtc.onAppPaused();
    } else if (state == AppLifecycleState.resumed) {
      _signal.onAppResumed();
      _webrtc.onAppResumed();
    }
  }

  /// Frees the camera for the QR scanner. Not possible during a call.
  Future<bool> _prepareForScan() async {
    if (_webrtc.isCallActive) return false;
    await _media.stop();
    return true;
  }

  void _selectTab(int index) {
    setState(() => _tab = index);
    // The camera and its permissions are only requested when the camera
    // tab is opened for the first time.
    if (index == _cameraTab && _media.status == LocalMediaStatus.idle) {
      unawaited(_media.start());
    }
  }

  @override
  Widget build(BuildContext context) {
    final isHost = widget.role == CallRole.host;
    return Scaffold(
      appBar: AppBar(title: Text(isHost ? 'Host' : 'Join')),
      body: SafeArea(
        child: IndexedStack(
          index: _tab,
          children: [
            ConnectionPanel(
              signal: _signal,
              role: widget.role,
              callActive: _callActive,
              prepareForScan: _prepareForScan,
            ),
            _CameraTab(
              media: _media,
              signal: _signal,
              webrtc: _webrtc,
              showDiagnostics: _showDiagnostics,
            ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: _selectTab,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.wifi), label: 'Connection'),
          NavigationDestination(icon: Icon(Icons.videocam), label: 'Camera'),
        ],
      ),
    );
  }
}

class _CameraTab extends StatelessWidget {
  const _CameraTab({
    required this.media,
    required this.signal,
    required this.webrtc,
    required this.showDiagnostics,
  });

  final LocalMediaService media;
  final LocalSignalService signal;
  final WebRtcService webrtc;
  final ValueNotifier<bool> showDiagnostics;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[media, signal, webrtc]),
      builder: (context, _) {
        return Column(
          children: [
            _StatusBar(
              text:
                  'Signaling: ${signal.statusText}\n'
                  'Call: ${webrtc.statusText}',
              warning: media.warning ?? webrtc.warning,
            ),
            CallStatusPanel(
              webrtc: webrtc,
              onQualityTap: () =>
                  showDiagnostics.value = !showDiagnostics.value,
            ),
            ValueListenableBuilder<bool>(
              valueListenable: showDiagnostics,
              builder: (context, show, _) {
                if (!show || !webrtc.isCallActive) {
                  return const SizedBox.shrink();
                }
                return DiagnosticsPanel(
                  diagnostics: webrtc.stats.diagnostics,
                  onClose: () => showDiagnostics.value = false,
                );
              },
            ),
            Expanded(
              child: _VideoArea(media: media, webrtc: webrtc),
            ),
            _CallActions(webrtc: webrtc),
            CallControls(
              mediaReady: media.isReady,
              micEnabled: media.micEnabled,
              cameraEnabled: media.cameraEnabled,
              canSwitchCamera:
                  media.isReady &&
                  media.canSwitchCamera &&
                  !media.isSwitchingCamera,
              speakerOn: webrtc.speakerOn,
              canToggleSpeaker: webrtc.isCallActive,
              onToggleMic: media.toggleMicrophone,
              onToggleCamera: media.toggleCamera,
              onSwitchCamera: () => unawaited(media.switchCamera()),
              onToggleSpeaker: () => unawaited(webrtc.toggleSpeaker()),
              // Ending a call keeps signaling (and the Host) running. With
              // no call, End leaves the screen as it did before.
              onEndCall: () {
                if (webrtc.isCallActive || webrtc.hasIncomingCall) {
                  unawaited(webrtc.hangUp());
                } else {
                  Navigator.of(context).maybePop();
                }
              },
            ),
          ],
        );
      },
    );
  }
}

/// Start / accept / decline buttons.
class _CallActions extends StatelessWidget {
  const _CallActions({required this.webrtc});

  final WebRtcService webrtc;

  @override
  Widget build(BuildContext context) {
    if (webrtc.hasIncomingCall) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => unawaited(webrtc.hangUp()),
                child: const Text('Decline'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                onPressed: () => unawaited(webrtc.startCall()),
                icon: const Icon(Icons.call),
                label: const Text('Accept call'),
              ),
            ),
          ],
        ),
      );
    }
    if (webrtc.isCallActive) return const SizedBox.shrink();
    final retry = webrtc.hasFailed || webrtc.phase == CallPhase.ended;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: webrtc.canStartCall
              ? () => unawaited(webrtc.startCall())
              : null,
          icon: Icon(retry ? Icons.refresh : Icons.call),
          label: Text(
            !webrtc.signalingConnected
                ? 'Connect on the Connection tab first'
                : retry
                ? 'Start call again'
                : 'Start call',
          ),
        ),
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.text, this.warning});

  final String text;
  final String? warning;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(Icons.info_outline, color: scheme.onSecondaryContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  warning == null ? text : '$text\n$warning',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSecondaryContainer,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VideoArea extends StatelessWidget {
  const _VideoArea({required this.media, required this.webrtc});

  final LocalMediaService media;
  final WebRtcService webrtc;

  static const double _padding = 12;
  static const double _previewWidthFraction = 0.3;
  static const double _previewMinWidth = 96;
  static const double _previewMaxWidth = 160;
  static const double _previewAspect = 4 / 3;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final previewWidth = (constraints.maxWidth * _previewWidthFraction)
            .clamp(_previewMinWidth, _previewMaxWidth)
            .toDouble();
        return Padding(
          padding: const EdgeInsets.all(_padding),
          child: Stack(
            children: [
              Positioned.fill(
                child: webrtc.milestones.remoteTrack
                    ? RemoteVideoView(
                        renderer: webrtc.remoteRenderer,
                        framesArriving: webrtc.milestones.remoteVideoFrames,
                      )
                    : _RemotePlaceholder(text: webrtc.statusText),
              ),
              if (media.hasProblem)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: _MediaProblemCard(media: media),
                ),
              Positioned(
                top: _padding,
                right: _padding,
                width: previewWidth,
                height: previewWidth * _previewAspect,
                child: LocalVideoPreview(media: media),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _RemotePlaceholder extends StatelessWidget {
  const _RemotePlaceholder({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      label: 'Remote video placeholder',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.person_outline,
                size: 64,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(height: 8),
              Text('Remote video', style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  text,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MediaProblemCard extends StatelessWidget {
  const _MediaProblemCard({required this.media});

  final LocalMediaService media;

  @override
  Widget build(BuildContext context) {
    final permanentlyDenied =
        media.status == LocalMediaStatus.permissionPermanentlyDenied;
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(media.message ?? 'The camera is not available.'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                if (permanentlyDenied)
                  OutlinedButton(
                    onPressed: () => unawaited(media.openSettings()),
                    child: const Text('Open app settings'),
                  ),
                FilledButton(
                  onPressed: () => unawaited(media.start()),
                  child: const Text('Try again'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

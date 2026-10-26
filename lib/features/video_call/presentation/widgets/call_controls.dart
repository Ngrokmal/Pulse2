import 'package:flutter/material.dart';

/// Bottom control bar: mute, camera on/off, flip camera, end call.
class CallControls extends StatelessWidget {
  const CallControls({
    super.key,
    required this.mediaReady,
    required this.micEnabled,
    required this.cameraEnabled,
    required this.canSwitchCamera,
    required this.speakerOn,
    required this.canToggleSpeaker,
    required this.onToggleMic,
    required this.onToggleCamera,
    required this.onSwitchCamera,
    required this.onToggleSpeaker,
    required this.onEndCall,
  });

  final bool mediaReady;
  final bool micEnabled;
  final bool cameraEnabled;
  final bool canSwitchCamera;
  final bool speakerOn;
  final bool canToggleSpeaker;
  final VoidCallback onToggleMic;
  final VoidCallback onToggleCamera;
  final VoidCallback onSwitchCamera;
  final VoidCallback onToggleSpeaker;
  final VoidCallback onEndCall;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _ControlButton(
              icon: micEnabled ? Icons.mic : Icons.mic_off,
              label: micEnabled ? 'Mute' : 'Unmute',
              onPressed: mediaReady ? onToggleMic : null,
              isOff: !micEnabled,
            ),
          ),
          Expanded(
            child: _ControlButton(
              icon: cameraEnabled ? Icons.videocam : Icons.videocam_off,
              label: cameraEnabled ? 'Camera off' : 'Camera on',
              onPressed: mediaReady ? onToggleCamera : null,
              isOff: !cameraEnabled,
            ),
          ),
          Expanded(
            child: _ControlButton(
              icon: Icons.cameraswitch,
              label: 'Flip',
              onPressed: canSwitchCamera ? onSwitchCamera : null,
            ),
          ),
          Expanded(
            child: _ControlButton(
              icon: speakerOn ? Icons.volume_up : Icons.hearing,
              label: speakerOn ? 'Speaker' : 'Earpiece',
              onPressed: canToggleSpeaker ? onToggleSpeaker : null,
            ),
          ),
          Expanded(
            child: _ControlButton(
              icon: Icons.call_end,
              label: 'End',
              onPressed: onEndCall,
              isDanger: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.isDanger = false,
    this.isOff = false,
  });

  static const double _buttonSize = 56;
  static const double _iconSize = 28;

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool isDanger;

  /// The thing this button controls is currently switched off (muted
  /// microphone, camera off). Drawn in the error colours with a strike-
  /// through icon so the state is clear without reading the label.
  final bool isOff;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sizeStyle = IconButton.styleFrom(
      minimumSize: const Size.square(_buttonSize),
    );

    final Widget button = isDanger
        ? IconButton.filled(
            onPressed: onPressed,
            tooltip: label,
            iconSize: _iconSize,
            icon: Icon(icon),
            style: sizeStyle.copyWith(
              backgroundColor: WidgetStatePropertyAll(scheme.error),
              foregroundColor: WidgetStatePropertyAll(scheme.onError),
            ),
          )
        : isOff
        ? IconButton.filled(
            onPressed: onPressed,
            tooltip: label,
            iconSize: _iconSize,
            icon: Icon(icon),
            style: sizeStyle.copyWith(
              backgroundColor: WidgetStatePropertyAll(scheme.errorContainer),
              foregroundColor: WidgetStatePropertyAll(scheme.onErrorContainer),
            ),
          )
        : IconButton.filledTonal(
            onPressed: onPressed,
            tooltip: label,
            iconSize: _iconSize,
            icon: Icon(icon),
            style: sizeStyle,
          );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        button,
        const SizedBox(height: 4),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ],
    );
  }
}

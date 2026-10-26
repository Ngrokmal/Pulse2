import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../services/local_media_service.dart';

/// Small self-view of the local camera.
class LocalVideoPreview extends StatelessWidget {
  const LocalVideoPreview({super.key, required this.media});

  final LocalMediaService media;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Local camera preview',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: ColoredBox(
          color: scheme.surfaceContainerHighest,
          child: _buildContent(),
        ),
      ),
    );
  }

  Widget _buildContent() {
    switch (media.status) {
      case LocalMediaStatus.ready:
        return Stack(
          fit: StackFit.expand,
          children: [
            RTCVideoView(
              media.renderer,
              mirror: media.isFrontCamera,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            ),
            if (!media.cameraEnabled)
              const ColoredBox(
                color: Colors.black87,
                child: Center(
                  child: Icon(Icons.videocam_off, color: Colors.white70),
                ),
              ),
          ],
        );
      case LocalMediaStatus.idle:
      case LocalMediaStatus.starting:
        return const Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      case LocalMediaStatus.permissionDenied:
      case LocalMediaStatus.permissionPermanentlyDenied:
      case LocalMediaStatus.noCamera:
      case LocalMediaStatus.error:
        return const Center(child: Icon(Icons.no_photography_outlined));
    }
  }
}

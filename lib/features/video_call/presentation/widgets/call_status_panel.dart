import 'package:flutter/material.dart';

import '../../models/call_state.dart';
import '../../services/webrtc_service.dart';
import 'call_quality_badge.dart';

/// Shows each call milestone separately, so "connected" is never claimed
/// from the WebSocket alone.
class CallStatusPanel extends StatelessWidget {
  const CallStatusPanel({super.key, required this.webrtc, this.onQualityTap});

  final WebRtcService webrtc;

  /// Called when the quality indicator is tapped (opens the diagnostics).
  final VoidCallback? onQualityTap;

  @override
  Widget build(BuildContext context) {
    final milestones = webrtc.milestones;
    final phase = webrtc.phase;
    final inCall = phase.isActive;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 0,
            children: [
              _MilestoneChip('Signaling', webrtc.signalingConnected),
              _MilestoneChip('Negotiated', milestones.negotiated),
              _MilestoneChip('ICE connected', milestones.iceConnected),
              _MilestoneChip('Remote track', milestones.remoteTrack),
              _MilestoneChip('Video frames', milestones.remoteVideoFrames),
              _MilestoneChip('Audio bytes', milestones.remoteAudioFlowing),
            ],
          ),
          if (inCall)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  ValueListenableBuilder<Duration>(
                    valueListenable: webrtc.callDuration,
                    builder: (context, duration, _) {
                      final showTime =
                          phase == CallPhase.connected ||
                          phase == CallPhase.mediaFlowing;
                      return Text(
                        showTime ? _format(duration) : '--:--',
                        style: Theme.of(context).textTheme.labelMedium,
                      );
                    },
                  ),
                  const SizedBox(width: 8),
                  CallQualityBadge(
                    quality: webrtc.stats.quality,
                    onTap: onQualityTap,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${webrtc.snapshot.describe().replaceAll('\n', ' | ')}'
                      ' | ${webrtc.candidateSummary}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _format(Duration duration) {
    final minutes = duration.inMinutes.toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _MilestoneChip extends StatelessWidget {
  const _MilestoneChip(this.label, this.done);

  final String label;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Chip(
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      avatar: Icon(
        done ? Icons.check_circle : Icons.radio_button_unchecked,
        size: 16,
        color: done ? scheme.primary : scheme.outline,
      ),
      label: Text(label, style: Theme.of(context).textTheme.labelSmall),
    );
  }
}

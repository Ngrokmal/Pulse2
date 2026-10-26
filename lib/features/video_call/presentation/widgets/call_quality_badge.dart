import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models/call_quality.dart';

/// Small connection-quality indicator: a coloured dot and one word.
///
/// It listens only to [quality], which changes when the shown state changes
/// (not once per statistics sample), so it does not cause frequent rebuilds.
class CallQualityBadge extends StatelessWidget {
  const CallQualityBadge({super.key, required this.quality, this.onTap});

  final ValueListenable<CallQuality> quality;

  /// Opens or closes the diagnostics panel.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CallQuality>(
      valueListenable: quality,
      builder: (context, value, _) {
        final scheme = Theme.of(context).colorScheme;
        final color = colorFor(value, scheme);
        return Semantics(
          button: onTap != null,
          label: 'Connection quality: ${value.label}',
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    value.label,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  static Color colorFor(CallQuality quality, ColorScheme scheme) {
    switch (quality) {
      case CallQuality.good:
        return Colors.green.shade600;
      case CallQuality.fair:
        return Colors.amber.shade700;
      case CallQuality.poor:
        return scheme.error;
      case CallQuality.connecting:
      case CallQuality.reconnecting:
        return Colors.orange.shade600;
      case CallQuality.disconnected:
        return scheme.outline;
    }
  }
}

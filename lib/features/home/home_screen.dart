import 'package:flutter/material.dart';

import '../video_call/models/call_role.dart';
import '../video_call/presentation/call_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  static const double _maxContentWidth = 420;
  static const double _buttonHeight = 56;

  void _openCall(BuildContext context, CallRole role) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => CallScreen(role: role)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final buttonStyle = FilledButton.styleFrom(
      minimumSize: const Size.fromHeight(_buttonHeight),
    );

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _maxContentWidth),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.video_call_rounded,
                    size: 72,
                    color: scheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Offline Video Call',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Internet-free local video calling',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 32),
                  FilledButton.icon(
                    style: buttonStyle,
                    onPressed: () => _openCall(context, CallRole.host),
                    icon: const Icon(Icons.wifi_tethering),
                    label: const Text('Host'),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    style: buttonStyle,
                    onPressed: () => _openCall(context, CallRole.join),
                    icon: const Icon(Icons.login),
                    label: const Text('Join'),
                  ),
                  const SizedBox(height: 24),
                  const _InfoRow(
                    icon: Icons.wifi,
                    text: 'Both phones must connect to the same Wi-Fi hotspot.',
                  ),
                  const SizedBox(height: 16),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.tertiaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        'Phones connect over the hotspot, then start a '
                        'video call from the Camera tab. Video and audio go '
                        'directly between the phones; nothing uses the '
                        'internet. Some hotspots block traffic between '
                        'phones and then the call cannot connect.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onTertiaryContainer,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
      ],
    );
  }
}

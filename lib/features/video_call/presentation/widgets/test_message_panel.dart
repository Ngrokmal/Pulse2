import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/signal_message.dart';
import '../../services/local_signal_service.dart';

/// Test-message input and ping/pong round-trip time, shown while connected.
class TestMessagePanel extends StatefulWidget {
  const TestMessagePanel({super.key, required this.signal});

  final LocalSignalService signal;

  @override
  State<TestMessagePanel> createState() => _TestMessagePanelState();
}

class _TestMessagePanelState extends State<TestMessagePanel> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _send() {
    widget.signal.sendChat(_controller.text);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rtt = widget.signal.lastRttMs;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Test messages',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                Text(
                  rtt == null ? 'Round trip: \u2014' : 'Round trip: $rtt ms',
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Send ping',
                  onPressed: widget.signal.sendPing,
                  icon: const Icon(Icons.network_ping),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    textInputAction: TextInputAction.send,
                    inputFormatters: [
                      LengthLimitingTextInputFormatter(kMaxChatChars),
                    ],
                    decoration: const InputDecoration(
                      labelText: 'Test message',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: 'Send message',
                  onPressed: _send,
                  icon: const Icon(Icons.send),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Scrollable list of connection events and test messages.
class ActivityLog extends StatelessWidget {
  const ActivityLog({super.key, required this.entries});

  final List<SignalLogEntry> entries;

  static const double _height = 240;

  static String _two(int value) => value.toString().padLeft(2, '0');

  static String _time(DateTime time) =>
      '${_two(time.hour)}:${_two(time.minute)}:${_two(time.second)}';

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Activity', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            SizedBox(
              height: _height,
              child: ListView.builder(
                reverse: true,
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final entry = entries[entries.length - 1 - index];
                  final who = switch (entry.kind) {
                    LogKind.sent => 'You',
                    LogKind.received => 'Peer',
                    LogKind.system => '\u2022',
                  };
                  final color = switch (entry.kind) {
                    LogKind.sent => scheme.primary,
                    LogKind.received => scheme.tertiary,
                    LogKind.system => scheme.onSurfaceVariant,
                  };
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '${_time(entry.time)}  ',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          TextSpan(
                            text: '$who: ',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: color,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          TextSpan(
                            text: entry.text,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

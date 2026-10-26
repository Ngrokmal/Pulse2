import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/call_role.dart';
import '../../models/connection_validators.dart';
import '../../models/pairing_payload.dart';
import '../../models/session_tokens.dart';
import '../../services/local_signal_service.dart';
import '../../services/network_discovery_service.dart';
import '../qr_scan_screen.dart';
import 'host_qr_card.dart';
import 'test_message_panel.dart';
import 'package:flutter/foundation.dart';

/// Host / Join controls, connection status and test messages.
class ConnectionPanel extends StatefulWidget {
  const ConnectionPanel({
    super.key,
    required this.signal,
    required this.role,
    this.callActive,
    this.prepareForScan,
  });

  final LocalSignalService signal;
  final CallRole role;

  /// True while a call is running: the camera is busy, so scanning is off.
  final ValueListenable<bool>? callActive;

  /// Called before the QR scanner opens, to free the camera. Returns false
  /// when scanning is not possible right now.
  final Future<bool> Function()? prepareForScan;

  @override
  State<ConnectionPanel> createState() => _ConnectionPanelState();
}

class _ConnectionPanelState extends State<ConnectionPanel> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _hostController = TextEditingController();
  final TextEditingController _portController = TextEditingController(
    text: LocalSignalService.defaultPort.toString(),
  );
  final TextEditingController _codeController = TextEditingController();
  bool _showQr = false;
  bool _scanning = false;

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  void _startHost() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    final port = parsePort(_portController.text);
    if (port == null) return;
    unawaited(widget.signal.startHost(port: port));
  }

  void _join() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final port = parsePort(_portController.text);
    if (port == null) return;
    FocusScope.of(context).unfocus();
    unawaited(
      widget.signal.join(
        host: _hostController.text.trim(),
        port: port,
        pairingCode: _codeController.text.trim(),
      ),
    );
  }

  void _say(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// Opens the scanner, asks the user to confirm, then joins. Nothing is
  /// connected before the user confirms the address shown in the dialog.
  Future<void> _scanAndJoin() async {
    if (_scanning) return;
    setState(() => _scanning = true);
    try {
      final prepare = widget.prepareForScan;
      final ready = prepare == null ? true : await prepare();
      if (!mounted) return;
      if (!ready) {
        _say('End the current call before scanning a QR code.');
        return;
      }
      final payload = await Navigator.of(context).push<PairingPayload>(
        MaterialPageRoute<PairingPayload>(builder: (_) => const QrScanScreen()),
      );
      if (!mounted || payload == null) return; // cancelled
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Join this host?'),
          content: Text(
            'Connect to the phone at ${payload.endpoint}? Only continue if '
            'you are looking at the host phone that showed this QR code.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Join'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      _hostController.text = payload.host;
      _portController.text = payload.port.toString();
      _codeController.clear();
      FocusScope.of(context).unfocus();
      unawaited(
        widget.signal.join(
          host: payload.host,
          port: payload.port,
          sessionSecret: payload.secret,
        ),
      );
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Widget _scanButton() {
    Widget button(bool callActive) {
      return OutlinedButton.icon(
        onPressed: (_scanning || callActive)
            ? null
            : () => unawaited(_scanAndJoin()),
        icon: const Icon(Icons.qr_code_scanner),
        label: Text(_scanning ? 'Opening scanner\u2026' : 'Scan QR code'),
      );
    }

    final listenable = widget.callActive;
    if (listenable == null) return button(false);
    return ValueListenableBuilder<bool>(
      valueListenable: listenable,
      builder: (context, active, _) => button(active),
    );
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Copied')));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.signal,
      builder: (context, _) {
        final signal = widget.signal;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _StatusCard(signal: signal),
            const SizedBox(height: 12),
            if (widget.role == CallRole.host)
              ..._hostSection(context, signal)
            else
              ..._clientSection(context, signal),
            if (signal.isConnected) ...[
              const SizedBox(height: 12),
              TestMessagePanel(signal: signal),
            ],
            const SizedBox(height: 12),
            ActivityLog(entries: signal.log),
            const SizedBox(height: 12),
            const _LimitationsCard(),
          ],
        );
      },
    );
  }

  List<Widget> _hostSection(BuildContext context, LocalSignalService signal) {
    final theme = Theme.of(context);
    if (!signal.isHostRunning) {
      _showQr = false;
      final starting = signal.phase == SignalPhase.starting;
      return [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Turn on your hotspot in Android Settings first. The app '
                    'does not change Wi-Fi settings for you.',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _portController,
                    enabled: !starting,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(5),
                    ],
                    decoration: const InputDecoration(
                      labelText: 'Port',
                      helperText: 'Default 8080 (1024\u201365535)',
                      border: OutlineInputBorder(),
                    ),
                    validator: validateHostPortNumber,
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: starting ? null : _startHost,
                    icon: const Icon(Icons.wifi_tethering),
                    label: Text(starting ? 'Starting\u2026' : 'Start Host'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ];
    }

    final port = signal.listeningPort;
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Tell the other phone', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text('IP address and port', style: theme.textTheme.labelLarge),
              if (signal.addresses.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    signal.addressError ??
                        'No address found automatically. Check the hotspot '
                            'IP in Android Settings. Port: $port',
                  ),
                )
              else
                for (final address in signal.addresses)
                  _AddressTile(address: address, port: port, onCopy: _copy),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => unawaited(signal.refreshAddresses()),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh addresses'),
                ),
              ),
              const Divider(),
              Text('Pairing code', style: theme.textTheme.labelLarge),
              Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      signal.pairingCode ?? '',
                      style: theme.textTheme.displaySmall?.copyWith(
                        fontFamily: 'monospace',
                        letterSpacing: 4,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy pairing code',
                    onPressed: () => unawaited(_copy(signal.pairingCode ?? '')),
                    icon: const Icon(Icons.copy),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              if (!signal.isConnected && signal.sessionSecret != null) ...[
                OutlinedButton.icon(
                  onPressed: () => setState(() => _showQr = !_showQr),
                  icon: const Icon(Icons.qr_code_2),
                  label: Text(_showQr ? 'Hide QR code' : 'Show QR code'),
                ),
                if (_showQr)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: HostQrCard(
                      addresses: signal.addresses,
                      port: port,
                      secret: signal.sessionSecret!,
                    ),
                  ),
                const SizedBox(height: 8),
              ],
              Text(
                signal.isConnected
                    ? 'Connected phone: ${signal.peerAddress ?? 'unknown'}'
                    : 'Connected phone: none yet',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: () => unawaited(signal.stop()),
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('Stop Host'),
              ),
            ],
          ),
        ),
      ),
    ];
  }

  List<Widget> _clientSection(BuildContext context, LocalSignalService signal) {
    final phase = signal.phase;
    final working =
        phase == SignalPhase.connecting || phase == SignalPhase.handshaking;
    final connected = signal.isConnected;
    final canEdit = !working && !connected;
    final showRetry =
        (phase == SignalPhase.disconnected || phase == SignalPhase.error) &&
        signal.canRetry;

    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Join the same hotspot in Android Settings, then enter '
                  'what the host phone shows.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _hostController,
                  enabled: canEdit,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    LengthLimitingTextInputFormatter(15),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Host IP address',
                    hintText: '192.168.1.10',
                    border: OutlineInputBorder(),
                  ),
                  validator: validateIPv4Address,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _portController,
                  enabled: canEdit,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(5),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Port',
                    border: OutlineInputBorder(),
                  ),
                  validator: validatePortNumber,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _codeController,
                  enabled: canEdit,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(kPairingCodeLength),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Pairing code',
                    border: OutlineInputBorder(),
                  ),
                  validator: validatePairingCode,
                ),
                const SizedBox(height: 16),
                if (!working && !connected) ...[
                  FilledButton.icon(
                    onPressed: _scanning ? null : _join,
                    icon: const Icon(Icons.login),
                    label: const Text('Join'),
                  ),
                  const SizedBox(height: 8),
                  _scanButton(),
                ],
                if (working || connected)
                  FilledButton.tonalIcon(
                    onPressed: () => unawaited(signal.stop()),
                    icon: const Icon(Icons.link_off),
                    label: Text(working ? 'Cancel' : 'Disconnect'),
                  ),
                if (showRetry) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () => unawaited(signal.retry()),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ];
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.signal});

  final LocalSignalService signal;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final phase = signal.phase;
    final IconData icon;
    final Color background;
    final Color foreground;
    switch (phase) {
      case SignalPhase.connected:
        icon = Icons.check_circle_outline;
        background = scheme.primaryContainer;
        foreground = scheme.onPrimaryContainer;
      case SignalPhase.error:
        icon = Icons.error_outline;
        background = scheme.errorContainer;
        foreground = scheme.onErrorContainer;
      case SignalPhase.starting:
      case SignalPhase.connecting:
      case SignalPhase.handshaking:
        icon = Icons.sync;
        background = scheme.secondaryContainer;
        foreground = scheme.onSecondaryContainer;
      case SignalPhase.listening:
        icon = Icons.wifi_tethering;
        background = scheme.secondaryContainer;
        foreground = scheme.onSecondaryContainer;
      case SignalPhase.idle:
      case SignalPhase.disconnected:
        icon = Icons.link_off;
        background = scheme.surfaceContainerHigh;
        foreground = scheme.onSurface;
    }
    return Semantics(
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(icon, color: foreground),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  signal.statusText,
                  style: TextStyle(color: foreground),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddressTile extends StatelessWidget {
  const _AddressTile({
    required this.address,
    required this.port,
    required this.onCopy,
  });

  final LocalAddress address;
  final int? port;
  final Future<void> Function(String text) onCopy;

  @override
  Widget build(BuildContext context) {
    final text = port == null ? address.address : '${address.address}:$port';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: SelectableText(
        text,
        style: Theme.of(context).textTheme.titleMedium,
      ),
      subtitle: Text('${address.label} \u00b7 ${address.interfaceName}'),
      trailing: IconButton(
        tooltip: 'Copy address',
        onPressed: () => unawaited(onCopy(text)),
        icon: const Icon(Icons.copy),
      ),
    );
  }
}

class _LimitationsCard extends StatelessWidget {
  const _LimitationsCard();

  static const List<String> _notes = <String>[
    'You turn on the hotspot and join it in Android Settings. The app never '
        'does this for you.',
    'The hotspot IP differs between phone brands. Address labels are '
        'guesses; if unsure, check the hotspot details in Android Settings.',
    'Some phones block traffic between hotspot devices. If the connection '
        'times out, try another phone as host.',
    'The pairing code or QR secret is never sent; only a proof of it is. '
        'But the signaling channel (ws://) is not encrypted, so anyone who '
        'can see traffic on the hotspot can read the call setup. Video and '
        'audio are encrypted by WebRTC. This is a prototype.',
    'Android may pause the app in the background and drop the connection.',
    'After connecting here, open the Camera tab and tap Start call on both '
        'phones. Whether video and audio really flow is shown there.',
  ];

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ExpansionTile(
        title: const Text('Limitations and notes'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final note in _notes)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('\u2022 '),
                  Expanded(child: Text(note)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

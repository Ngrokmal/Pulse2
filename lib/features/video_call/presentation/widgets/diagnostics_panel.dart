import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models/diagnostics_format.dart';
import '../../services/call_stats_service.dart';

/// Optional panel with the real measurements of the current call.
///
/// It sits in the layout above the video (the video area gets smaller
/// instead of being covered) and can be closed without touching the call.
/// A dash means the platform did not report that value.
class DiagnosticsPanel extends StatelessWidget {
  const DiagnosticsPanel({
    super.key,
    required this.diagnostics,
    required this.onClose,
  });

  final ValueListenable<CallDiagnostics> diagnostics;
  final VoidCallback onClose;

  static const double _maxHeight = 200;
  static const double _maxHeightFraction = 0.25;

  static double _maxHeightFor(double screenHeight) {
    final limit = screenHeight * _maxHeightFraction;
    return limit < _maxHeight ? limit : _maxHeight;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: ConstrainedBox(
          // On a small screen the panel never takes more than a quarter of
          // the height, so the video and the call controls stay usable.
          constraints: BoxConstraints(
            maxHeight: _maxHeightFor(MediaQuery.sizeOf(context).height),
          ),
          child: Stack(
            children: [
              ValueListenableBuilder<CallDiagnostics>(
                valueListenable: diagnostics,
                builder: (context, value, _) {
                  return SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(12, 10, 44, 10),
                    child: _Rows(diagnostics: value),
                  );
                },
              ),
              Positioned(
                top: 0,
                right: 0,
                child: IconButton(
                  tooltip: 'Close diagnostics',
                  iconSize: 20,
                  visualDensity: VisualDensity.compact,
                  onPressed: onClose,
                  icon: const Icon(Icons.close),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Rows extends StatelessWidget {
  const _Rows({required this.diagnostics});

  final CallDiagnostics diagnostics;

  static const String _dash = DiagnosticsFormat.unavailable;

  @override
  Widget build(BuildContext context) {
    final m = diagnostics.metrics;
    final report = diagnostics.report;
    final f = DiagnosticsFormat.text;
    final rows = <(String, String)>[
      (
        'Quality',
        report.reason == null
            ? report.quality.label
            : '${report.quality.label} \u2013 ${report.reason}',
      ),
      if (report.deviceLimited)
        ('Device', 'Encoder limited by this phone\u2019s CPU'),
      (
        'Sending',
        '${DiagnosticsFormat.size(m.txWidth, m.txHeight)} '
            '@ ${DiagnosticsFormat.fps(m.txVideoFps)} '
            '\u00b7 ${DiagnosticsFormat.kbps(m.txVideoKbps)}',
      ),
      (
        'Encoder',
        '${f(m.txCodec)} \u00b7 ${f(m.txEncoder)} '
            '\u00b7 limited by: ${f(m.qualityLimitation)}',
      ),
      (
        'Receiving',
        '${DiagnosticsFormat.size(m.rxWidth, m.rxHeight)} '
            '@ ${DiagnosticsFormat.fps(m.rxVideoFps)} '
            '\u00b7 ${DiagnosticsFormat.kbps(m.rxVideoKbps)}',
      ),
      ('Decoder', '${f(m.rxCodec)} \u00b7 ${f(m.rxDecoder)}'),
      (
        'Audio',
        'out ${DiagnosticsFormat.kbps(m.txAudioKbps)} '
            '\u00b7 in ${DiagnosticsFormat.kbps(m.rxAudioKbps)}',
      ),
      (
        'Packet loss',
        'in video ${DiagnosticsFormat.percent(m.rxVideoLossPct)} '
            '\u00b7 in audio ${DiagnosticsFormat.percent(m.rxAudioLossPct)} '
            '\u00b7 out ${DiagnosticsFormat.percent(m.outboundLossPct)}',
      ),
      (
        'Latency',
        'RTT ${DiagnosticsFormat.milliseconds(m.rttMs)} '
            '\u00b7 jitter ${DiagnosticsFormat.milliseconds(m.jitterMs)}',
      ),
      (
        'Path',
        '${f(m.localCandidateType)} \u2192 ${f(m.remoteCandidateType)} '
            '\u00b7 ${f(m.candidateProtocol)} \u00b7 ${f(m.networkType)}',
      ),
      (
        'Data',
        'sent ${DiagnosticsFormat.bytes(m.totalBytesSent)} '
            '\u00b7 received ${DiagnosticsFormat.bytes(m.totalBytesReceived)}',
      ),
      (
        'Send limit',
        diagnostics.adaptationActive && diagnostics.step != null
            ? '${diagnostics.step} (step ${diagnostics.stepLevel + 1} of '
                  '${diagnostics.stepCount})'
            : 'fixed${diagnostics.step == null ? '' : ' at ${diagnostics.step}'}',
      ),
      if (diagnostics.adaptationNote != null)
        ('Adaptation', diagnostics.adaptationNote!),
      ('Samples', '${diagnostics.samples} \u00b7 $_dash = not reported'),
    ];

    final theme = Theme.of(context);
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final valueStyle = theme.textTheme.labelSmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 78, child: Text(row.$1, style: labelStyle)),
                Expanded(child: Text(row.$2, style: valueStyle)),
              ],
            ),
          ),
      ],
    );
  }
}

// Widget tests for connection and call state in the UI. They use fake data
// and no sockets or cameras. They check what the screens show, not that a
// real call works.
// ignore_for_file: avoid_relative_lib_imports
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../lib/features/video_call/models/call_quality.dart';
import '../lib/features/video_call/models/call_role.dart';
import '../lib/features/video_call/models/call_stats.dart';
import '../lib/features/video_call/presentation/widgets/call_controls.dart';
import '../lib/features/video_call/presentation/widgets/call_quality_badge.dart';
import '../lib/features/video_call/presentation/widgets/connection_panel.dart';
import '../lib/features/video_call/presentation/widgets/diagnostics_panel.dart';
import '../lib/features/video_call/presentation/widgets/host_qr_card.dart';
import '../lib/features/video_call/services/call_stats_service.dart';
import '../lib/features/video_call/services/local_signal_service.dart';
import '../lib/features/video_call/services/network_discovery_service.dart';

const String _secret = '0123456789abcdef0123456789abcdef';

class _NoDiscovery extends NetworkDiscoveryService {
  const _NoDiscovery();

  @override
  Future<AddressDiscoveryResult> listLocalAddresses() async {
    return const AddressDiscoveryResult(addresses: <LocalAddress>[]);
  }
}

Widget _app(Widget child) => MaterialApp(home: Scaffold(body: child));

void _tallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  group('CallQualityBadge', () {
    testWidgets('shows the label of the current state and updates', (
      tester,
    ) async {
      final quality = ValueNotifier<CallQuality>(CallQuality.connecting);
      addTearDown(quality.dispose);
      await tester.pumpWidget(_app(CallQualityBadge(quality: quality)));
      expect(find.text('Connecting'), findsOneWidget);
      for (final state in CallQuality.values) {
        quality.value = state;
        await tester.pump();
        expect(find.text(state.label), findsOneWidget, reason: '$state');
      }
    });

    testWidgets('is tappable when a handler is given', (tester) async {
      final quality = ValueNotifier<CallQuality>(CallQuality.good);
      addTearDown(quality.dispose);
      var taps = 0;
      await tester.pumpWidget(
        _app(CallQualityBadge(quality: quality, onTap: () => taps++)),
      );
      await tester.tap(find.text('Good'));
      expect(taps, 1);
    });
  });

  group('DiagnosticsPanel', () {
    testWidgets('unavailable values are dashes, never zero', (tester) async {
      final diagnostics = ValueNotifier<CallDiagnostics>(
        CallDiagnostics.initial,
      );
      addTearDown(diagnostics.dispose);
      await tester.pumpWidget(
        _app(DiagnosticsPanel(diagnostics: diagnostics, onClose: () {})),
      );
      expect(find.textContaining('not reported'), findsOneWidget);
      expect(find.textContaining('kbit/s'), findsNothing);
      expect(find.textContaining('Mbit/s'), findsNothing);
      expect(find.textContaining('0 fps'), findsNothing);
      expect(find.textContaining('0 ms'), findsNothing);
    });

    testWidgets('shows real measurements and updates', (tester) async {
      final diagnostics = ValueNotifier<CallDiagnostics>(
        const CallDiagnostics(
          metrics: CallMetrics(
            intervalValid: true,
            txVideoKbps: 850,
            txWidth: 1280,
            txHeight: 720,
            txVideoFps: 29.6,
            rttMs: 12,
          ),
          report: QualityReport(quality: CallQuality.good),
          link: CallLinkState.connected,
        ),
      );
      addTearDown(diagnostics.dispose);
      await tester.pumpWidget(
        _app(DiagnosticsPanel(diagnostics: diagnostics, onClose: () {})),
      );
      expect(find.textContaining('1280x720 @ 30 fps'), findsOneWidget);
      expect(find.textContaining('850 kbit/s'), findsWidgets);
      expect(find.textContaining('RTT 12 ms'), findsOneWidget);

      diagnostics.value = const CallDiagnostics(
        report: QualityReport(
          quality: CallQuality.poor,
          reason: 'High packet loss (12.0%)',
        ),
      );
      await tester.pump();
      expect(find.textContaining('High packet loss'), findsOneWidget);
    });

    testWidgets('can be closed with the close button', (tester) async {
      final diagnostics = ValueNotifier<CallDiagnostics>(
        CallDiagnostics.initial,
      );
      addTearDown(diagnostics.dispose);
      var closed = 0;
      await tester.pumpWidget(
        _app(
          DiagnosticsPanel(diagnostics: diagnostics, onClose: () => closed++),
        ),
      );
      await tester.tap(find.byTooltip('Close diagnostics'));
      expect(closed, 1);
    });

    testWidgets('stays small and does not overflow on a small screen', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final diagnostics = ValueNotifier<CallDiagnostics>(
        CallDiagnostics.initial,
      );
      addTearDown(diagnostics.dispose);
      await tester.pumpWidget(
        _app(DiagnosticsPanel(diagnostics: diagnostics, onClose: () {})),
      );
      expect(tester.takeException(), isNull);
      final size = tester.getSize(find.byType(DiagnosticsPanel));
      expect(size.height, lessThanOrEqualTo(480 * 0.25 + 8));
    });
  });

  group('CallControls', () {
    Widget controls({
      bool mediaReady = true,
      bool mic = true,
      bool camera = true,
      VoidCallback? onMic,
      VoidCallback? onEnd,
    }) {
      return _app(
        CallControls(
          mediaReady: mediaReady,
          micEnabled: mic,
          cameraEnabled: camera,
          canSwitchCamera: true,
          speakerOn: true,
          canToggleSpeaker: true,
          onToggleMic: onMic ?? () {},
          onToggleCamera: () {},
          onSwitchCamera: () {},
          onToggleSpeaker: () {},
          onEndCall: onEnd ?? () {},
        ),
      );
    }

    testWidgets('muted and camera-off states are labelled and drawn off', (
      tester,
    ) async {
      await tester.pumpWidget(controls(mic: false, camera: false));
      expect(find.text('Unmute'), findsOneWidget);
      expect(find.text('Camera on'), findsOneWidget);
      expect(find.byIcon(Icons.mic_off), findsOneWidget);
      expect(find.byIcon(Icons.videocam_off), findsOneWidget);

      await tester.pumpWidget(controls());
      expect(find.text('Mute'), findsOneWidget);
      expect(find.text('Camera off'), findsOneWidget);
      expect(find.byIcon(Icons.mic), findsOneWidget);
    });

    testWidgets('mute and camera do nothing until the media is ready', (
      tester,
    ) async {
      var mic = 0;
      await tester.pumpWidget(controls(mediaReady: false, onMic: () => mic++));
      await tester.tap(find.byTooltip('Mute'));
      expect(mic, 0);
      await tester.pumpWidget(controls(onMic: () => mic++));
      await tester.tap(find.byTooltip('Mute'));
      expect(mic, 1);
    });

    testWidgets('End is always available', (tester) async {
      var ended = 0;
      await tester.pumpWidget(
        controls(mediaReady: false, onEnd: () => ended++),
      );
      await tester.tap(find.byTooltip('End'));
      expect(ended, 1);
    });

    testWidgets('all five controls fit a 320 dp wide screen', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(controls(mic: false, camera: false));
      expect(tester.takeException(), isNull);
    });
  });

  group('ConnectionPanel', () {
    late LocalSignalService signal;

    setUp(() {
      signal = LocalSignalService(discovery: const _NoDiscovery());
    });

    tearDown(() => signal.dispose());

    testWidgets('join form shows what is missing and does not connect', (
      tester,
    ) async {
      _tallScreen(tester);
      await tester.pumpWidget(
        _app(ConnectionPanel(signal: signal, role: CallRole.join)),
      );
      expect(find.text('Not connected.'), findsOneWidget);
      await tester.tap(find.text('Join'));
      await tester.pump();
      expect(find.text('Enter the host IP address.'), findsOneWidget);
      expect(
        find.text('Enter the pairing code shown on the host.'),
        findsOneWidget,
      );
      expect(signal.phase, SignalPhase.idle);
    });

    testWidgets('join form rejects a bad address, port and code', (
      tester,
    ) async {
      _tallScreen(tester);
      await tester.pumpWidget(
        _app(ConnectionPanel(signal: signal, role: CallRole.join)),
      );
      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), '999.1.1');
      await tester.enterText(fields.at(1), '0');
      await tester.enterText(fields.at(2), '12');
      await tester.tap(find.text('Join'));
      await tester.pump();
      expect(find.text('Use the format 192.168.1.10'), findsOneWidget);
      expect(find.text('Enter a port from 1 to 65535.'), findsOneWidget);
      expect(find.text('The pairing code has 6 digits.'), findsOneWidget);
      expect(signal.phase, SignalPhase.idle);
    });

    testWidgets('the QR scan button is off while a call is running', (
      tester,
    ) async {
      _tallScreen(tester);
      final active = ValueNotifier<bool>(true);
      addTearDown(active.dispose);
      await tester.pumpWidget(
        _app(
          ConnectionPanel(
            signal: signal,
            role: CallRole.join,
            callActive: active,
          ),
        ),
      );
      expect(find.text('Scan QR code'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(find.bySubtype<OutlinedButton>())
            .onPressed,
        isNull,
      );
      active.value = false;
      await tester.pump();
      expect(
        tester
            .widget<OutlinedButton>(find.bySubtype<OutlinedButton>())
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('host form rejects a port Android would not allow', (
      tester,
    ) async {
      _tallScreen(tester);
      await tester.pumpWidget(
        _app(ConnectionPanel(signal: signal, role: CallRole.host)),
      );
      await tester.enterText(find.byType(TextFormField), '80');
      await tester.tap(find.text('Start Host'));
      await tester.pump();
      expect(find.text('Enter a port from 1024 to 65535.'), findsOneWidget);
      expect(signal.phase, SignalPhase.idle);
    });

    testWidgets('the limitations card does not claim encryption', (
      tester,
    ) async {
      _tallScreen(tester);
      await tester.pumpWidget(
        _app(ConnectionPanel(signal: signal, role: CallRole.host)),
      );
      await tester.tap(find.text('Limitations and notes'));
      await tester.pumpAndSettle();
      expect(find.textContaining('is not encrypted'), findsOneWidget);
    });
  });

  group('HostQrCard', () {
    const hotspot = LocalAddress(
      interfaceName: 'ap0',
      address: '192.168.43.1',
      kind: AddressKind.hotspotLikely,
    );
    const mobile = LocalAddress(
      interfaceName: 'rmnet0',
      address: '10.20.30.40',
      kind: AddressKind.mobileData,
    );
    const publicIp = LocalAddress(
      interfaceName: 'eth0',
      address: '8.8.8.8',
      kind: AddressKind.other,
    );
    const wifi = LocalAddress(
      interfaceName: 'wlan0',
      address: '192.168.1.20',
      kind: AddressKind.wifi,
    );

    testWidgets('draws one QR code for the usable address only', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          const SingleChildScrollView(
            child: HostQrCard(
              addresses: <LocalAddress>[hotspot, mobile, publicIp],
              port: 8080,
              secret: _secret,
            ),
          ),
        ),
      );
      expect(find.byType(QrImageView), findsOneWidget);
      expect(find.textContaining('192.168.43.1:8080'), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNothing);
      // The secret is inside the QR code only, never printed as text.
      expect(find.textContaining(_secret), findsNothing);
    });

    testWidgets('offers a choice when several addresses are usable', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          const SingleChildScrollView(
            child: HostQrCard(
              addresses: <LocalAddress>[hotspot, wifi],
              port: 9000,
              secret: _secret,
            ),
          ),
        ),
      );
      expect(find.byType(ChoiceChip), findsNWidgets(2));
      expect(find.textContaining('192.168.43.1:9000'), findsOneWidget);
      await tester.tap(find.text('192.168.1.20'));
      await tester.pump();
      expect(find.textContaining('192.168.1.20:9000'), findsOneWidget);
    });

    testWidgets('without a usable address it explains instead of guessing', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          const HostQrCard(
            addresses: <LocalAddress>[mobile, publicIp],
            port: 8080,
            secret: _secret,
          ),
        ),
      );
      expect(find.byType(QrImageView), findsNothing);
      expect(find.textContaining('No usable local address'), findsOneWidget);
    });
  });
}

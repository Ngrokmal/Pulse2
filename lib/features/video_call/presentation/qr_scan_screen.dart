import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/pairing_payload.dart';

enum _ScanState { requesting, scanning, denied, permanentlyDenied, error }

/// Scans the host's QR code and returns the validated [PairingPayload]
/// (or null when the user goes back).
///
/// Only text that parses as a valid Offline Video Call payload is accepted;
/// anything else shows a short message and scanning continues. The scanned
/// text is never logged or shown. The caller must still ask the user to
/// confirm before connecting.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  MobileScannerController? _controller;
  _ScanState _state = _ScanState.requesting;
  String? _problem;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      final status = await Permission.camera.request();
      if (!mounted) return;
      if (status.isGranted) {
        _controller = MobileScannerController(
          formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
          detectionSpeed: DetectionSpeed.noDuplicates,
        );
        setState(() => _state = _ScanState.scanning);
      } else if (status.isPermanentlyDenied) {
        setState(() => _state = _ScanState.permanentlyDenied);
      } else {
        setState(() => _state = _ScanState.denied);
      }
    } catch (error) {
      debugPrint('Preparing the QR scanner failed: ${error.runtimeType}');
      if (mounted) setState(() => _state = _ScanState.error);
    }
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.isEmpty) continue;
      try {
        final payload = PairingPayload.parse(raw);
        _done = true;
        Navigator.of(context).pop(payload);
        return;
      } on PairingPayloadException catch (error) {
        // Show why, never the scanned text itself.
        if (_problem != error.message && mounted) {
          setState(() => _problem = error.message);
        }
      }
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan host QR code')),
      body: SafeArea(child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    switch (_state) {
      case _ScanState.requesting:
        return const Center(child: CircularProgressIndicator());
      case _ScanState.denied:
        return _Message(
          icon: Icons.no_photography_outlined,
          text:
              'The camera permission is needed to scan the QR code. '
              'You can still join by typing the address and pairing code.',
          actions: [
            FilledButton(
              onPressed: () {
                setState(() => _state = _ScanState.requesting);
                unawaited(_prepare());
              },
              child: const Text('Allow camera'),
            ),
          ],
        );
      case _ScanState.permanentlyDenied:
        return _Message(
          icon: Icons.no_photography_outlined,
          text:
              'The camera permission was permanently denied. Allow it in '
              'the app settings, or join by typing the address and pairing '
              'code.',
          actions: [
            FilledButton(
              onPressed: () => unawaited(openAppSettings()),
              child: const Text('Open app settings'),
            ),
          ],
        );
      case _ScanState.error:
        return const _Message(
          icon: Icons.error_outline,
          text:
              'The QR scanner could not be started. You can still join by '
              'typing the address and pairing code.',
        );
      case _ScanState.scanning:
        final controller = _controller;
        return Column(
          children: [
            Expanded(
              child: controller == null
                  ? const SizedBox.shrink()
                  : ClipRect(
                      child: MobileScanner(
                        controller: controller,
                        onDetect: _onDetect,
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _problem ??
                    'Point the camera at the QR code shown on the host '
                        'phone. Nothing is connected until you confirm.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _problem == null
                      ? null
                      : Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          ],
        );
    }
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.text,
    this.actions = const <Widget>[],
  });

  final IconData icon;
  final String text;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ...actions,
          ],
        ),
      ),
    );
  }
}

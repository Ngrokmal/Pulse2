import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../models/connection_validators.dart';
import '../../models/pairing_payload.dart';
import '../../services/network_discovery_service.dart';

/// Shows the pairing QR code for one of this phone's local addresses.
///
/// The code contains the address, port and the session secret, so it is
/// built here from memory, drawn once, and never logged or stored. Show it
/// only to the phone you want to let in.
class HostQrCard extends StatefulWidget {
  const HostQrCard({
    super.key,
    required this.addresses,
    required this.port,
    required this.secret,
  });

  final List<LocalAddress> addresses;
  final int? port;
  final String secret;

  @override
  State<HostQrCard> createState() => _HostQrCardState();
}

class _HostQrCardState extends State<HostQrCard> {
  int _selected = 0;

  /// Addresses another phone could plausibly reach: private LAN IPv4 that
  /// is not a mobile-data interface.
  List<LocalAddress> get _usable => widget.addresses
      .where(
        (a) => a.kind != AddressKind.mobileData && isPrivateLanIPv4(a.address),
      )
      .toList(growable: false);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final usable = _usable;
    final port = widget.port;
    if (usable.isEmpty || port == null || port < kMinHostPort) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'No usable local address was found for a QR code. Use the '
          'address and pairing code above instead.',
          style: theme.textTheme.bodyMedium,
        ),
      );
    }
    final index = _selected < usable.length ? _selected : 0;
    final address = usable[index];
    final payload = PairingPayload(
      host: address.address,
      port: port,
      secret: widget.secret,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (usable.length > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(
              spacing: 8,
              children: [
                for (var i = 0; i < usable.length; i++)
                  ChoiceChip(
                    label: Text(usable[i].address),
                    selected: i == index,
                    onSelected: (_) => setState(() => _selected = i),
                  ),
              ],
            ),
          ),
        Semantics(
          label: 'QR code for joining this host',
          child: ColoredBox(
            color: Colors.white,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: QrImageView(
                data: payload.encode(),
                size: 220,
                backgroundColor: Colors.white,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'For ${payload.endpoint}. Only show this to the phone you want to '
          'let in. It contains the pairing secret.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

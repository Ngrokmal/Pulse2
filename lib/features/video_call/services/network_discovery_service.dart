import 'dart:io';

import 'package:flutter/foundation.dart';

enum AddressKind { hotspotLikely, wifi, mobileData, other }

/// One IPv4 address found on this phone.
class LocalAddress {
  const LocalAddress({
    required this.interfaceName,
    required this.address,
    required this.kind,
  });

  final String interfaceName;
  final String address;
  final AddressKind kind;

  /// Best-effort label. Android vendors name interfaces differently,
  /// so this is a hint, never a guarantee.
  String get label {
    switch (kind) {
      case AddressKind.hotspotLikely:
        return 'Possible hotspot address';
      case AddressKind.wifi:
        return 'Wi-Fi address (may also be the hotspot on some phones)';
      case AddressKind.mobileData:
        return 'Mobile data (the other phone cannot reach this)';
      case AddressKind.other:
        return 'Other network';
    }
  }
}

class AddressDiscoveryResult {
  const AddressDiscoveryResult({required this.addresses, this.errorMessage});

  final List<LocalAddress> addresses;

  /// Set when Android did not let the app list its network interfaces.
  final String? errorMessage;
}

/// Best-effort discovery of this phone's local IPv4 addresses.
class NetworkDiscoveryService {
  const NetworkDiscoveryService();

  Future<AddressDiscoveryResult> listLocalAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );
      final found = <LocalAddress>[];
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          found.add(
            LocalAddress(
              interfaceName: interface.name,
              address: address.address,
              kind: classify(interface.name),
            ),
          );
        }
      }
      found.sort((a, b) => a.kind.index.compareTo(b.kind.index));
      return AddressDiscoveryResult(addresses: found);
    } catch (error) {
      debugPrint('Listing network interfaces failed: ${error.runtimeType}');
      return const AddressDiscoveryResult(
        addresses: <LocalAddress>[],
        errorMessage:
            'Android did not let the app list its network '
            'addresses. Check the hotspot IP in Android Settings and type it '
            'on the other phone.',
      );
    }
  }

  /// Guesses what an Android interface name is used for.
  @visibleForTesting
  static AddressKind classify(String interfaceName) {
    final name = interfaceName.toLowerCase();
    const mobilePrefixes = <String>[
      'rmnet',
      'v4-rmnet',
      'ccmni',
      'pdp',
      'wwan',
      'data',
    ];
    if (mobilePrefixes.any(name.startsWith)) return AddressKind.mobileData;

    const hotspotPrefixes = <String>['ap', 'swlan', 'softap', 'wlan1'];
    if (hotspotPrefixes.any(name.startsWith)) return AddressKind.hotspotLikely;

    if (name.startsWith('wlan') || name.startsWith('wifi')) {
      return AddressKind.wifi;
    }
    return AddressKind.other;
  }
}

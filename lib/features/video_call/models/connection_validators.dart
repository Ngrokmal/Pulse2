/// Lowest port the host accepts. Android apps cannot bind lower ports.
const int kMinHostPort = 1024;
const int kMaxPort = 65535;

/// Returns an error text for form fields, or null for a valid IPv4 address.
String? validateIPv4Address(String? input) {
  final value = input?.trim() ?? '';
  if (value.isEmpty) return 'Enter the host IP address.';

  final parts = value.split('.');
  if (parts.length != 4) return 'Use the format 192.168.1.10';

  final digitsOnly = RegExp(r'^[0-9]+$');
  final octets = <int>[];
  for (final part in parts) {
    if (part.isEmpty || part.length > 3 || !digitsOnly.hasMatch(part)) {
      return 'Use the format 192.168.1.10';
    }
    if (part.length > 1 && part.startsWith('0')) {
      return 'Remove leading zeros (use 5, not 05).';
    }
    final octet = int.parse(part);
    if (octet > 255) return 'Each number must be between 0 and 255.';
    octets.add(octet);
  }

  if (octets.every((octet) => octet == 0)) {
    return '0.0.0.0 is not a device address.';
  }
  if (octets.first >= 224) {
    return 'This is not a normal device address.';
  }
  return null;
}

bool isValidIPv4Address(String? input) => validateIPv4Address(input) == null;

/// Parses a port, or returns null when it is not a number from 1 to 65535.
int? parsePort(String? input) {
  final value = input?.trim() ?? '';
  if (!RegExp(r'^[0-9]{1,5}$').hasMatch(value)) return null;
  final port = int.parse(value);
  return port >= 1 && port <= kMaxPort ? port : null;
}

String? validatePortNumber(String? input) {
  return parsePort(input) == null ? 'Enter a port from 1 to $kMaxPort.' : null;
}

/// Port check for the host: also requires a port Android allows apps to open.
String? validateHostPortNumber(String? input) {
  final port = parsePort(input);
  if (port == null || port < kMinHostPort) {
    return 'Enter a port from $kMinHostPort to $kMaxPort.';
  }
  return null;
}

/// True for the address ranges that only exist on a local network:
/// 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 and link-local 169.254.0.0/16.
/// Returns false for malformed input.
bool isPrivateLanIPv4(String? input) {
  if (validateIPv4Address(input) != null) return false;
  final octets = input!.trim().split('.').map(int.parse).toList();
  final a = octets[0];
  final b = octets[1];
  if (a == 10) return true;
  if (a == 172 && b >= 16 && b <= 31) return true;
  if (a == 192 && b == 168) return true;
  if (a == 169 && b == 254) return true;
  return false;
}

/// True when a connection from [address] may be served by the host: a
/// private LAN address, or this phone itself (loopback). Everything else
/// (public or carrier addresses) is refused before the WebSocket upgrade.
bool isAllowedPeerAddress(String? address) {
  if (address == null) return false;
  final value = address.trim();
  if (RegExp(r'^127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$').hasMatch(value)) {
    return true;
  }
  return isPrivateLanIPv4(value);
}

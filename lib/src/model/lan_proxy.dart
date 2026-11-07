import 'dart:io';

/// Current interface addresses are used only for selection and validation, not stored
/// in plugins or backups.
class LanInterfaceAddress {
  const LanInterfaceAddress({
    required this.address,
    required this.interfaceName,
    required this.interfaceIndex,
    required this.kind,
    this.available = true,
    this.platformSelectable = true,
    this.prefixLength,
  });

  final String address;
  final String interfaceName;
  final int interfaceIndex;
  final String kind;
  final bool available;
  final bool platformSelectable;
  final int? prefixLength;

  bool get selectable =>
      available &&
      platformSelectable &&
      !const ['cellular', 'vpn', 'loopback'].contains(kind) &&
      isConcreteLanAddress(address);
  bool get needsConfirmation => kind == 'unknown';

  String endpoint(int port) => lanEndpoint(address, port);
}

bool isConcreteLanAddress(String address) {
  if (address.isEmpty || address != address.trim()) return false;
  final pieces = address.split('%');
  if (pieces.length > 2 || pieces.length == 2 && pieces.last.isEmpty) {
    return false;
  }
  final ip = InternetAddress.tryParse(pieces.first);
  if (ip == null || ip.isLoopback || ip.isMulticast) return false;
  if (ip.rawAddress.every((byte) => byte == 0)) return false;
  if (pieces.length == 2 && ip.type != InternetAddressType.IPv6) return false;
  return true;
}

String lanEndpoint(String address, int port) =>
    address.contains(':') ? '[$address]:$port' : '$address:$port';

class LanProxyListenerState {
  const LanProxyListenerState({
    required this.name,
    required this.address,
    required this.port,
    required this.tcp,
    required this.udp,
    required this.udpRequired,
    this.error,
  });

  final String name;
  final String address;
  final int port;
  final bool tcp;
  final bool udp;
  final bool udpRequired;
  final String? error;

  bool get running => tcp && (!udpRequired || udp) && error == null;
  String get endpoint => lanEndpoint(address, port);
}

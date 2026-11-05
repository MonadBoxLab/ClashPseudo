import 'package:flutter/material.dart';

import '../../../../l10n/app_localizations.dart';
import '../shared/editor.dart'
    show definitionToolbarHeight, definitionToolbarTitle;

enum ProxyFormCategory { standard, community, vpn, builtin }

/// Raw ParseProxy type branches exposed by the selected mihomo dependency.
enum ProxyFormType {
  http('http', 'HTTP', ProxyFormCategory.standard),
  socks5('socks5', 'SOCKS5', ProxyFormCategory.standard),
  ssh('ssh', 'SSH', ProxyFormCategory.standard),
  masque('masque', 'MASQUE', ProxyFormCategory.standard),
  shadowsocks('ss', 'Shadowsocks', ProxyFormCategory.community),
  shadowsocksr('ssr', 'ShadowsocksR', ProxyFormCategory.community),
  vmess('vmess', 'VMess', ProxyFormCategory.community),
  vless('vless', 'VLESS', ProxyFormCategory.community),
  snell('snell', 'Snell', ProxyFormCategory.community),
  trojan('trojan', 'Trojan', ProxyFormCategory.community),
  hysteria('hysteria', 'Hysteria', ProxyFormCategory.community),
  hysteria2('hysteria2', 'Hysteria2', ProxyFormCategory.community),
  tuic('tuic', 'TUIC', ProxyFormCategory.community),
  shadowquic('shadowquic', 'ShadowQUIC', ProxyFormCategory.community),
  gostRelay('gost-relay', 'gost-relay', ProxyFormCategory.community),
  mieru('mieru', 'Mieru', ProxyFormCategory.community),
  anytls('anytls', 'AnyTLS', ProxyFormCategory.community),
  sudoku('sudoku', 'Sudoku', ProxyFormCategory.community),
  trusttunnel('trusttunnel', 'TrustTunnel', ProxyFormCategory.community),
  wireguard('wireguard', 'WireGuard', ProxyFormCategory.vpn),
  openvpn('openvpn', 'OpenVPN', ProxyFormCategory.vpn),
  zerotier('zerotier', 'ZeroTier', ProxyFormCategory.vpn),
  easytier('easytier', 'EasyTier', ProxyFormCategory.vpn),
  tailscale('tailscale', 'Tailscale', ProxyFormCategory.vpn),
  direct('direct', 'direct', ProxyFormCategory.builtin),
  dns('dns', 'dns', ProxyFormCategory.builtin),
  reject('reject', 'reject', ProxyFormCategory.builtin),
  rematch('rematch', 'rematch', ProxyFormCategory.builtin);

  const ProxyFormType(this.raw, this.label, this.category);
  final String raw;
  final String label;
  final ProxyFormCategory category;

  static ProxyFormType fromRaw(String raw) => values.firstWhere(
    (type) => type.raw == raw,
    orElse: () => throw ArgumentError.value(raw, 'type'),
  );
}

/// A single vertical choice page. Each raw proxy type appears exactly once.
class ProxyFormTypePage extends StatelessWidget {
  const ProxyFormTypePage({super.key, required this.selectedType});

  final String selectedType;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: _build);

  Widget _build(BuildContext context, BoxConstraints constraints) {
    final strings = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: definitionToolbarTitle(context, strings.proxyFormType),
        toolbarHeight: definitionToolbarHeight(
          context,
          strings.proxyFormType,
          constraints.maxWidth,
        ),
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: ListView(
              key: const PageStorageKey('proxy-type-list'),
              children: [
                for (final category in const [
                  ProxyFormCategory.standard,
                  ProxyFormCategory.community,
                  ProxyFormCategory.vpn,
                ]) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
                    child: Text(
                      switch (category) {
                        ProxyFormCategory.standard =>
                          strings.proxyCategoryStandard,
                        ProxyFormCategory.community =>
                          strings.proxyCategoryCommunity,
                        ProxyFormCategory.vpn => strings.proxyCategoryVpn,
                        ProxyFormCategory.builtin =>
                          strings.proxyCategoryBuiltin,
                      },
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  for (final type in ProxyFormType.values.where(
                    (type) => type.category == category,
                  )) ...[
                    ListTile(
                      key: ValueKey('proxy-type:${type.raw}'),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                      ),
                      title: Text(
                        type.label,
                        style: TextStyle(
                          fontWeight: selectedType == type.raw
                              ? FontWeight.w700
                              : FontWeight.w400,
                        ),
                      ),
                      selected: selectedType == type.raw,
                      selectedColor: theme.colorScheme.onSurface,
                      selectedTileColor:
                          theme.colorScheme.surfaceContainerHighest,
                      onTap: () {
                        // A retained callback must not select for a covered or
                        // already exiting choice route.
                        if (!context.mounted ||
                            ModalRoute.of(context)?.isCurrent != true) {
                          return;
                        }
                        Navigator.pop(context, type.raw);
                      },
                    ),
                    const Divider(height: 1, indent: 20, endIndent: 20),
                  ],
                ],
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

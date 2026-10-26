import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../l10n/app_localizations.dart';
import '../../platform/app_bridge.dart';

class AboutPage extends StatefulWidget {
  const AboutPage({super.key, required this.platform});
  final AppBridge platform;

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  late Future<Map<String, dynamic>> _info = _read();

  Future<Map<String, dynamic>> _read() =>
      widget.platform.applicationInfo().timeout(const Duration(seconds: 5));

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final icons = SettingsPalette(
      Theme.of(context).brightness == Brightness.dark,
    );
    return Scaffold(
      appBar: AppBar(title: Text(strings.about)),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  'Clash Pseudo',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                const Text('MonadBox Lab'),
                const SizedBox(height: 24),
                FutureBuilder<Map<String, dynamic>>(
                  future: _info,
                  builder: (context, snapshot) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(strings.applicationVersion),
                        subtitle: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Text(
                            snapshot.data?['version'] as String? ?? '—',
                            softWrap: false,
                          ),
                        ),
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(strings.coreVersion),
                        subtitle: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Text(
                            snapshot.data?['coreVersion'] as String? ??
                                (snapshot.hasError
                                    ? strings.versionUnavailable
                                    : '—'),
                            softWrap: false,
                          ),
                        ),
                        trailing: SizedBox.square(
                          dimension: 48,
                          child:
                              snapshot.connectionState ==
                                  ConnectionState.waiting
                              ? const Center(
                                  child: SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                )
                              : snapshot.hasError
                              ? IconButton(
                                  tooltip:
                                      '${strings.versionUnavailable} ${strings.retry}',
                                  onPressed: () {
                                    final next = _read();
                                    setState(() {
                                      _info = next;
                                    });
                                  },
                                  color: HomePalette.of(context).syncAction,
                                  icon: const Icon(Icons.refresh),
                                )
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 32),
                SelectableText(strings.legalSummary),
                const SizedBox(height: 16),
                Text(strings.sourceDistributionNotice),
                const SizedBox(height: 16),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.description_outlined,
                    color: icons.configuration,
                  ),
                  title: Text(strings.licenses),
                  trailing: Icon(
                    Icons.chevron_right,
                    color: icons.configuration,
                  ),
                  onTap: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) =>
                          const LicensePage(applicationName: 'Clash Pseudo'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

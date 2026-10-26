import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';

void registerAppLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(const [
      'Clash Pseudo (GPL-3.0-only)',
    ], await rootBundle.loadString('LICENSE'));
    yield LicenseEntryWithLineBreaks(const [
      'mihomo',
    ], await rootBundle.loadString('third_party/notices/mihomo.txt'));
    yield LicenseEntryWithLineBreaks(const [
      'Go',
    ], await rootBundle.loadString('third_party/notices/go.txt'));
    yield LicenseEntryWithLineBreaks(const [
      'Android',
    ], await rootBundle.loadString('third_party/notices/android.txt'));
    yield LicenseEntryWithLineBreaks(const [
      'Material Icons',
    ], await rootBundle.loadString('third_party/notices/material-icons.txt'));
    yield LicenseEntryWithLineBreaks(const [
      're_editor',
    ], await rootBundle.loadString('third_party/sources/re_editor/LICENSE'));
    final mpl = await rootBundle.loadString(
      'third_party/data/certificates/MPL-2.0.txt',
    );
    yield LicenseEntryWithLineBreaks(
      const ['Mozilla CA data (curl 2026-09-25)'],
      '${await rootBundle.loadString('third_party/data/certificates/NOTICE.txt')}\n\n$mpl',
    );
    yield LicenseEntryWithLineBreaks(
      const ['Public Suffix List (63cbc63d470d)'],
      '${await rootBundle.loadString('third_party/notices/publicsuffix.txt')}\n\n$mpl',
    );
    final geo = <String>[
      for (final file in const [
        'NOTICE.txt',
        'CC-BY-SA-4.0.txt',
        'GeoSite-MIT.txt',
        'CC-BY-4.0.txt',
      ])
        await rootBundle.loadString('third_party/data/geodata/$file'),
    ].join('\n\n');
    yield LicenseEntryWithLineBreaks(const [
      'GeoIP.dat / GeoSite.dat / Country.mmdb / ASN.mmdb',
    ], geo);
  });
}

Future<void> showAppLegal(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) {
    final strings = AppLocalizations.of(context);
    return AlertDialog(
      scrollable: true,
      title: Text(strings.aboutTitle),
      content: Text(strings.legalBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) =>
                  const LicensePage(applicationName: 'Clash Pseudo'),
            ),
          ),
          child: Text(strings.licensesAndNotices),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(strings.close),
        ),
      ],
    );
  },
);

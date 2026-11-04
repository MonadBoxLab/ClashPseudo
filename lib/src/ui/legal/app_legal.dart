import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../model/messages.dart';
import '../components/feedback/operation_feedback.dart';
import '../locale/message_text.dart';

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
      'build/generated/bundled/legal/certificates/MPL-2.0.txt',
    );
    yield LicenseEntryWithLineBreaks(
      const ['Mozilla CA data'],
      '${await rootBundle.loadString('build/generated/bundled/legal/certificates/NOTICE.txt')}\n\n$mpl',
    );
    yield LicenseEntryWithLineBreaks(
      const ['Public Suffix List'],
      '${await rootBundle.loadString('third_party/notices/publicsuffix.txt')}\n\n$mpl',
    );
    final geo = <String>[
      for (final file in const [
        'NOTICE.txt',
        'CC-BY-SA-4.0.txt',
        'GeoSite-MIT.txt',
        'CC-BY-4.0.txt',
      ])
        await rootBundle.loadString(
          'build/generated/bundled/legal/geodata/$file',
        ),
    ].join('\n\n');
    yield LicenseEntryWithLineBreaks(const [
      'GeoIP.dat / GeoSite.dat / Country.mmdb / ASN.mmdb',
    ], geo);
  });
}

/// The About entry opens the full notice, not the installation-only prompt.
Future<void> showPrivacyNotice(BuildContext context) => Navigator.of(context)
    .push<void>(MaterialPageRoute(builder: (_) => const PrivacyNoticePage()));

bool _legalRouteActive(BuildContext context) {
  final route = ModalRoute.of(context);
  return context.mounted &&
      route?.isCurrent == true &&
      route?.animation?.status != AnimationStatus.reverse;
}

/// SDK routes own the animation; exiting content loses eligibility immediately.
class LegalRouteContent extends StatelessWidget {
  const LegalRouteContent({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final route = ModalRoute.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([
        route?.animation,
        route?.secondaryAnimation,
      ]),
      child: child,
      builder: (context, child) {
        final active = _legalRouteActive(context);
        return IgnorePointer(
          ignoring: !active,
          child: ExcludeFocus(
            excluding: !active,
            child: ExcludeSemantics(excluding: !active, child: child!),
          ),
        );
      },
    );
  }
}

class PrivacyNoticeDialog extends StatefulWidget {
  const PrivacyNoticeDialog({super.key, this.persistenceFailure});

  final AppMessage? persistenceFailure;

  @override
  State<PrivacyNoticeDialog> createState() => _PrivacyNoticeDialogState();
}

class _PrivacyNoticeDialogState extends State<PrivacyNoticeDialog> {
  // Only the local failure content moves when reduced motion bypasses the wrapper.
  final _failureContentKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final failureContent = KeyedSubtree(
      key: _failureContentKey,
      child: widget.persistenceFailure == null
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.persistenceFailure!.summary(strings)),
                  if (widget.persistenceFailure!.technicalDetail(strings) !=
                      null)
                    TextButton.icon(
                      key: const ValueKey('privacy-notice-error-details'),
                      onPressed: () {
                        if (!_legalRouteActive(context)) return;
                        showAppMessage(
                          context,
                          widget.persistenceFailure!,
                          title: (strings) => strings.privacyNoticeTitle,
                        );
                      },
                      icon: const Icon(Icons.error_outline),
                      label: Text(strings.errorDetails),
                    ),
                ],
              ),
            ),
    );
    return LegalRouteContent(
      child: AlertDialog(
        scrollable: true,
        title: Text(strings.privacyNoticeTitle),
        content: SelectionArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(strings.privacyNoticeIntro),
              const SizedBox(height: 16),
              const _LocalGplLink(),
              if (MediaQuery.disableAnimationsOf(context))
                failureContent
              else
                AnimatedSize(
                  duration: const Duration(milliseconds: 160),
                  alignment: Alignment.topLeft,
                  child: failureContent,
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              if (_legalRouteActive(context)) showPrivacyNotice(context);
            },
            child: Text(strings.privacyNoticeReadFull),
          ),
          TextButton(
            onPressed: () {
              if (_legalRouteActive(context)) Navigator.pop(context);
            },
            child: Text(strings.privacyNoticeUnderstood),
          ),
        ],
      ),
    );
  }
}

class _LocalGplLink extends StatelessWidget {
  const _LocalGplLink();

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return TextButton(
      style: TextButton.styleFrom(
        alignment: Alignment.centerLeft,
        padding: EdgeInsets.zero,
        minimumSize: const Size(48, 48),
      ),
      onPressed: () {
        if (!_legalRouteActive(context)) return;
        Navigator.of(
          context,
        ).push<void>(MaterialPageRoute(builder: (_) => const _LocalGplPage()));
      },
      child: Text(strings.privacyNoticeLicenseNotice),
    );
  }
}

class _LegalParagraphGap extends StatelessWidget {
  const _LegalParagraphGap({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    // Selection joins Text contents, not the visual spacing between widgets.
    child: const Text(
      '\n\n',
      textScaler: TextScaler.noScaling,
      style: TextStyle(fontSize: 1, height: 1),
    ),
  );
}

class PrivacyNoticePage extends StatelessWidget {
  const PrivacyNoticePage({super.key});

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final sections = [
      (strings.privacyDataProcessingTitle, strings.privacyDataProcessingBody),
      (
        strings.privacyNetworkCommunicationTitle,
        strings.privacyNetworkCommunicationBody,
      ),
      (
        strings.privacyPermissionPurposesTitle,
        strings.privacyPermissionPurposesBody,
      ),
      (strings.privacyFilesAndBackupsTitle, strings.privacyFilesAndBackupsBody),
      (strings.privacyRecordsAndLogsTitle, strings.privacyRecordsAndLogsBody),
      (strings.privacyDeletingDataTitle, strings.privacyDeletingDataBody),
      (strings.privacyProjectRepositoryTitle, strings.projectRepositoryUrl),
    ];
    return LegalRouteContent(
      child: Scaffold(
        appBar: AppBar(title: Text(strings.privacyNoticeTitle)),
        body: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 840),
              child: SelectionArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(strings.privacyNoticeIntro),
                      for (final (title, body) in sections) ...[
                        const _LegalParagraphGap(height: 24),
                        Semantics(
                          header: true,
                          child: Text(
                            title,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        const _LegalParagraphGap(height: 16),
                        Text(body),
                      ],
                      const _LegalParagraphGap(height: 16),
                      const _LocalGplLink(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LocalGplPage extends StatefulWidget {
  const _LocalGplPage();

  @override
  State<_LocalGplPage> createState() => _LocalGplPageState();
}

class _LocalGplPageState extends State<_LocalGplPage> {
  late Future<String> _license = rootBundle.loadString('LICENSE');

  @override
  Widget build(BuildContext context) => LegalRouteContent(
    child: Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context).privacyNoticeLicenseName),
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: FutureBuilder<String>(
              future: _license,
              builder: (context, snapshot) {
                if (snapshot.hasData) {
                  return SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: SelectableText(snapshot.requireData),
                  );
                }
                if (snapshot.hasError) {
                  return SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        Text(
                          AppLocalizations.of(context)
                              .operationNotCompletedRetry,
                        ),
                        TextButton.icon(
                          key: const ValueKey('license-load-error-details'),
                          onPressed: () {
                            if (!_legalRouteActive(context)) return;
                            showAppMessage(
                              context,
                              messages.operationNotCompletedRetry.withDetail(
                                snapshot.error,
                              ),
                              title: (strings) =>
                                  strings.privacyNoticeLicenseName,
                            );
                          },
                          icon: const Icon(Icons.error_outline),
                          label: Text(
                            AppLocalizations.of(context).errorDetails,
                          ),
                        ),
                        TextButton(
                          onPressed: () {
                            if (!_legalRouteActive(context)) return;
                            setState(
                              () => _license = rootBundle.loadString('LICENSE'),
                            );
                          },
                          child: Text(AppLocalizations.of(context).retry),
                        ),
                      ],
                    ),
                  );
                }
                return const Center(child: CircularProgressIndicator());
              },
            ),
          ),
        ),
      ),
    ),
  );
}

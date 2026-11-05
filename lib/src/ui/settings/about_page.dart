import 'dart:async';

import 'package:clash_pseudo/src/model/app_platform.dart';
import 'package:flutter/material.dart';

import '../legal/app_legal.dart';
import '../theme/app_theme.dart';
import '../../l10n/app_localizations.dart';
import '../components/feedback/operation_notice.dart';

class AboutPage extends StatefulWidget {
  const AboutPage({super.key, required this.platform});
  final AppPlatform platform;

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  late Future<Map<String, dynamic>> _info = _read();
  final _readChanges = ValueNotifier(0);
  Timer? _deadline;
  bool _reading = false;
  bool _timedOut = false;
  bool _retryQueued = false;
  int _failureVersion = 0;

  Future<Map<String, dynamic>> _read() {
    final info = widget.platform.applicationInfo();
    _reading = true;
    _timedOut = false;
    _deadline = Timer(const Duration(seconds: 5), () {
      if (mounted && identical(_info, info)) setState(() => _timedOut = true);
      _report(
        info,
        TimeoutException('Reading version information is still in progress'),
      );
    });
    unawaited(
      info.then<void>(
        (_) {
          if (!mounted || !identical(_info, info)) return;
          _deadline?.cancel();
          _deadline = null;
          _reading = false;
          _retryQueued = false;
          _failureVersion++;
          _readChanges.value++;
        },
        onError: (Object error, StackTrace stack) {
          if (!mounted || !identical(_info, info)) return;
          _deadline?.cancel();
          _deadline = null;
          _reading = false;
          if (_retryQueued && _active) {
            _retryQueued = false;
            unawaited(_retry(info));
          } else {
            _retryQueued = false;
            _report(info, error);
          }
        },
      ),
    );
    return info;
  }

  void _report(Future<Map<String, dynamic>> info, Object error) {
    if (!mounted || !identical(_info, info)) return;
    final version = ++_failureVersion;
    _readChanges.value++;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      bool current() =>
          _active && identical(_info, info) && version == _failureVersion;
      if (!current()) return;
      unawaited(
        showLocalizedOperationNotice(
          context,
          (strings) => strings.versionUnavailable,
          technicalDetail: (_) => error.toString(),
          title: (strings) => strings.coreVersion,
          isCurrent: current,
          isCurrentWithPopup: (_) =>
              mounted && identical(_info, info) && version == _failureVersion,
          onRetry: () => _retry(info),
          eligibilityChanges: _readChanges,
          identity: (info, version),
        ),
      );
    });
  }

  Future<void> _retry(Future<Map<String, dynamic>> info) async {
    if (!_active || !identical(_info, info)) return;
    if (_reading) {
      _retryQueued = true;
      return;
    }
    setState(() {
      _info = _read();
    });
    _readChanges.value++;
  }

  @override
  void dispose() {
    _deadline?.cancel();
    _readChanges.dispose();
    super.dispose();
  }

  bool get _active =>
      mounted &&
      ModalRoute.of(context)?.isCurrent == true &&
      ModalRoute.of(context)?.animation?.status != AnimationStatus.reverse;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final info = _info;
    final icons = SettingsPalette(
      Theme.of(context).brightness == Brightness.dark,
    );
    return LegalRouteContent(
      child: Scaffold(
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
                    future: info,
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
                              snapshot.data?['coreVersion'] as String? ?? '—',
                              softWrap: false,
                            ),
                          ),
                          trailing: SizedBox.square(
                            dimension: 48,
                            child:
                                snapshot.connectionState ==
                                        ConnectionState.waiting &&
                                    !_timedOut
                                ? const Center(
                                    child: SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  )
                                : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 24),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      Icons.privacy_tip_outlined,
                      color: icons.configuration,
                    ),
                    title: Text(strings.privacyNoticeTitle),
                    trailing: Icon(
                      Icons.chevron_right,
                      color: icons.configuration,
                    ),
                    onTap: () {
                      if (_active) showPrivacyNotice(context);
                    },
                  ),
                  SelectableText(strings.legalSummary),
                  const SizedBox(height: 16),
                  Text(strings.sourceDistributionNotice),
                  const SizedBox(height: 16),
                  Text(
                    strings.privacyProjectRepositoryTitle,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  SelectableText(strings.projectRepositoryUrl),
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
                    onTap: () {
                      if (!_active) return;
                      Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => const LegalRouteContent(
                            child: LicensePage(applicationName: 'Clash Pseudo'),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

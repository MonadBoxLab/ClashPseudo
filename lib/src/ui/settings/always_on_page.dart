import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../navigation/task_activity.dart';
import '../theme/app_theme.dart';
import '../components/feedback/operation_feedback.dart';
import '../components/feedback/operation_notice.dart';
import '../../l10n/app_localizations.dart';

class AlwaysOnPage extends StatefulWidget {
  const AlwaysOnPage({super.key, required this.app});
  final AppController app;
  @override
  State<AlwaysOnPage> createState() => _AlwaysOnPageState();
}

class _AlwaysOnPageState extends State<AlwaysOnPage> {
  bool _readFailed = false;
  Object? _statusError;
  final _feedbackChanges = ValueNotifier(0);
  bool? _alwaysOn;
  bool? _lockdown;
  int _request = 0;
  int _failures = 0;
  Timer? _retry;
  Timer? _deadline;
  bool _reading = false;
  bool _readAgain = false;
  bool _readAgainReport = false;
  int _openSerial = 0;
  bool _opening = false;
  bool _active = false;
  bool _readingDetails = false;
  Object? _detailError;
  (Object, (int, String), int)? _pendingError;
  ModalRoute<dynamic>? _route;
  ModalRoute<dynamic>? _detailsRoute;
  late (int, String) _session;

  @override
  void initState() {
    super.initState();
    _session = (widget.app.state.generation, widget.app.state.phase);
    widget.app.addListener(_appChanged);
  }

  bool get _eligible => _current();

  bool _current({ModalRoute<dynamic>? popup}) =>
      mounted &&
      widget.app.interactive &&
      AppTaskActivity.isActive(context, ownedPopup: popup) &&
      AppTaskActivity.routeIsActive(_route, ownedPopup: popup);

  bool get _detailsActive => _readingDetails && _current(popup: _detailsRoute);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    if (_syncVisibility()) unawaited(_load());
  }

  bool _syncVisibility() {
    if (_detailsActive) return false;
    final active = _eligible;
    if (_active == active) return false;
    _active = active;
    if (active) {
      _readFailed = false;
      _failures = 0;
      return true;
    }
    _request++;
    _openSerial++;
    _opening = false;
    _retry?.cancel();
    return false;
  }

  void _appChanged() {
    final session = (widget.app.state.generation, widget.app.state.phase);
    final changed = _session != session;
    _session = session;
    final entered = _syncVisibility();
    if (changed) {
      _request++;
      _openSerial++;
      _opening = false;
      _readFailed = false;
      _statusError = null;
      _pendingError = null;
      _failures = 0;
    }
    if (entered || changed) {
      if (_eligible) {
        unawaited(_load());
      } else if (_detailsActive) {
        _readAgain = true;
      }
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _request++;
    _retry?.cancel();
    _deadline?.cancel();
    widget.app.removeListener(_appChanged);
    _feedbackChanges.dispose();
    super.dispose();
  }

  void _scheduleRetry() {
    if (!_eligible || !_readFailed || _reading || _retry?.isActive == true) {
      return;
    }
    const backoff = [5, 10, 30, 60];
    final seconds = backoff[(_failures - 1).clamp(0, 3)];
    _retry = Timer(Duration(seconds: seconds), _load);
  }

  void _reportStatusFailure(Object error, (int, String) session, int request) {
    final owner = widget.app;
    bool sameSource() =>
        mounted &&
        identical(widget.app, owner) &&
        session == _session &&
        request == _request &&
        (identical(_statusError, error) ||
            _readingDetails && identical(_detailError, error));
    String summary(AppLocalizations strings) => strings.vpnStatusReadFailed;
    String detail(AppLocalizations _) => error.toString();
    Future<void> showDetails() async {
      _readingDetails = true;
      _detailError = error;
      try {
        await showLocalizedOperationMessage(
          context,
          summary,
          technicalDetail: detail,
          title: (strings) => strings.errorDetails,
          eligibilityChanges: Listenable.merge([owner, _feedbackChanges]),
          isCurrent: () => sameSource() && _eligible,
          isCurrentWithPopup: (popup) => sameSource() && _current(popup: popup),
          onRoute: (route) => _detailsRoute = route,
          onRetry: () => _load(reportFailure: true),
        );
      } finally {
        _readingDetails = false;
        _detailsRoute = null;
        _detailError = null;
        if (mounted) {
          _syncVisibility();
          if (_eligible) {
            final pending = _pendingError;
            _pendingError = null;
            if (pending != null &&
                _readFailed &&
                pending.$2 == _session &&
                pending.$3 == _request) {
              _reportStatusFailure(pending.$1, pending.$2, pending.$3);
            }
            if (_readAgain && !_reading) {
              unawaited(_load(reportFailure: _readAgainReport));
            } else {
              _scheduleRetry();
            }
          }
        }
      }
    }

    unawaited(
      showLocalizedOperationNotice(
        context,
        summary,
        technicalDetail: detail,
        isCurrent: () => sameSource() && _eligible,
        isCurrentWithPopup: (popup) => sameSource() && _current(popup: popup),
        eligibilityChanges: Listenable.merge([owner, _feedbackChanges]),
        onRetry: () => _load(reportFailure: true),
        onDetails: showDetails,
        identity: ('vpn-status', session, request),
      ),
    );
  }

  Future<void> _load({bool reportFailure = false}) async {
    if (!_eligible) return;
    if (_reading) {
      if (reportFailure) _request++;
      _readAgain = true;
      _readAgainReport |= reportFailure;
      return;
    }
    _retry?.cancel();
    _readAgain = _readAgainReport = false;
    _reading = true;
    final owner = widget.app;
    final session = _session;
    final request = ++_request;
    bool current() =>
        mounted &&
        identical(widget.app, owner) &&
        (_eligible || _detailsActive) &&
        session == _session &&
        request == _request;
    var failed = false;
    void failure(Object error) {
      if (!current()) return;
      final notify = !_readFailed || reportFailure || failed;
      if (!failed) _failures++;
      failed = true;
      _readFailed = true;
      if (!notify) return;
      _statusError = error;
      if (_detailsActive) {
        _pendingError = (error, session, request);
      } else {
        _reportStatusFailure(error, session, request);
      }
    }

    _deadline = Timer(const Duration(seconds: 5), () {
      failure(TimeoutException('Reading VPN status is still in progress'));
    });
    try {
      final value = await owner.platform.vpnStatus();
      if (!current()) return;
      setState(() {
        _alwaysOn = value['alwaysOn'] as bool?;
        _lockdown = value['lockdown'] as bool?;
        _readFailed = false;
        _statusError = null;
        _pendingError = null;
        _failures = 0;
      });
      _feedbackChanges.value++;
    } catch (error) {
      failure(error);
    } finally {
      _deadline?.cancel();
      _deadline = null;
      _reading = false;
      if (mounted && _eligible) {
        if (_readAgain) {
          final report = _readAgainReport;
          unawaited(_load(reportFailure: report));
        } else {
          _scheduleRetry();
        }
      }
    }
  }

  Future<void> _open() async {
    if (!_eligible || _opening) return;
    final serial = ++_openSerial;
    final session = _session;
    bool sameSource() =>
        mounted &&
        widget.app.interactive &&
        serial == _openSerial &&
        session == _session;
    bool current() => sameSource() && _eligible;
    setState(() => _opening = true);
    _feedbackChanges.value++;
    try {
      // Open Android VPN settings without another confirmation.
      await widget.app.platform.openVpnSettings();
      if (current()) unawaited(_load());
    } catch (error) {
      if (!mounted || !current()) return;
      await showLocalizedOperationNotice(
        context,
        (strings) => strings.alwaysOnOpenFailed,
        technicalDetail: (_) => error.toString(),
        isCurrent: current,
        eligibilityChanges: Listenable.merge([widget.app, _feedbackChanges]),
        identity: ('vpn-settings', session, serial),
        isCurrentWithPopup: (popup) =>
            mounted &&
            widget.app.interactive &&
            session == _session &&
            AppTaskActivity.isActive(context, ownedPopup: popup) &&
            AppTaskActivity.routeIsActive(_route, ownedPopup: popup),
      );
    } finally {
      if (mounted && serial == _openSerial) {
        setState(() => _opening = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final icons = SettingsPalette(
      Theme.of(context).brightness == Brightness.dark,
    );
    String state(bool? value, {required String on, required String off}) =>
        value == null
        ? strings.alwaysOnUnknown
        : value
        ? on
        : off;
    return IgnorePointer(
      ignoring: !_eligible,
      child: ExcludeFocus(
        excluding: !_eligible,
        child: ExcludeSemantics(
          excluding: !_eligible,
          child: Scaffold(
            appBar: AppBar(title: Text(strings.alwaysOnTitle)),
            body: SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 840),
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Text(
                        strings.alwaysOnNotice,
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(height: 1.5),
                      ),
                      const SizedBox(height: 20),
                      Card(
                        child: Column(
                          children: [
                            ListTile(
                              leading: Icon(
                                Icons.shield_outlined,
                                color: icons.network,
                              ),
                              title: Text(strings.alwaysOnTitle),
                              subtitle: Text(
                                state(
                                  _alwaysOn,
                                  on: strings.alwaysOnEnabled,
                                  off: strings.alwaysOnDisabled,
                                ),
                                maxLines: 1,
                                softWrap: false,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            ListTile(
                              leading: Icon(
                                Icons.lock_outline,
                                color: icons.extension,
                              ),
                              title: Text(strings.lockdownTitle),
                              subtitle: Text(
                                state(
                                  _lockdown,
                                  on: strings.lockdownEnabled,
                                  off: strings.lockdownDisabled,
                                ),
                                maxLines: 1,
                                softWrap: false,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        strings.lockdownNotice,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        strings.alwaysOnRestoreNotice,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        key: const ValueKey('always-on-settings'),
                        onPressed: !_eligible || _opening ? null : _open,
                        icon: const Icon(Icons.open_in_new),
                        label: Text(strings.openVpnSettings),
                      ),
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

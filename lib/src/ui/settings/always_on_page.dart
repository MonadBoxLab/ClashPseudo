import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../navigation/task_activity.dart';
import '../theme/app_theme.dart';
import '../components/feedback/operation_notice.dart';
import '../../l10n/app_localizations.dart';

class AlwaysOnPage extends StatefulWidget {
  const AlwaysOnPage({super.key, required this.app});
  final AppController app;
  @override
  State<AlwaysOnPage> createState() => _AlwaysOnPageState();
}

class _AlwaysOnPageState extends State<AlwaysOnPage> {
  bool _loading = true;
  bool _readFailed = false;
  final _feedbackChanges = ValueNotifier(0);
  bool? _alwaysOn;
  bool? _lockdown;
  int _request = 0;
  int _openSerial = 0;
  bool _opening = false;
  bool _active = false;
  ModalRoute<dynamic>? _route;
  late bool _foreground;
  late (int, String) _session;

  @override
  void initState() {
    super.initState();
    _foreground = widget.app.foreground;
    _session = (widget.app.state.generation, widget.app.state.phase);
    widget.app.addListener(_appChanged);
  }

  bool get _liveRoute => AppTaskActivity.routeIsActive(_route);

  bool get _eligible =>
      mounted &&
      widget.app.foreground &&
      AppTaskActivity.isActive(context) &&
      _liveRoute;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    final active = AppTaskActivity.isActive(context) && _liveRoute;
    if (_active == active) return;
    _active = active;
    if (active) {
      unawaited(_load());
    } else {
      _request++;
      _openSerial++;
      _opening = false;
      _loading = false;
    }
  }

  void _appChanged() {
    final foreground = widget.app.foreground;
    final session = (widget.app.state.generation, widget.app.state.phase);
    if (_foreground == foreground && _session == session) return;
    _foreground = foreground;
    if (_session != session) _readFailed = false;
    _session = session;
    _openSerial++;
    _opening = false;
    if (foreground) {
      if (_eligible) {
        unawaited(_load());
      } else {
        setState(() {});
      }
    } else {
      _request++;
      setState(() {
        _opening = false;
        _loading = false;
        _alwaysOn = null;
        _lockdown = null;
      });
    }
  }

  @override
  void dispose() {
    _request++;
    widget.app.removeListener(_appChanged);
    _feedbackChanges.dispose();
    super.dispose();
  }

  Future<void> _load({bool reportFailure = false}) async {
    if (!_eligible) return;
    final request = ++_request;
    setState(() => _loading = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _feedbackChanges.value++;
    });
    try {
      final value = await widget.app.platform.vpnStatus().timeout(
        const Duration(seconds: 5),
      );
      if (!mounted || !_eligible || request != _request) return;
      setState(() {
        _alwaysOn = value['alwaysOn'] as bool?;
        _lockdown = value['lockdown'] as bool?;
        _loading = false;
        _readFailed = false;
      });
    } catch (error) {
      if (!mounted || !_eligible || request != _request) return;
      final notify = reportFailure || !_readFailed;
      setState(() {
        _alwaysOn = null;
        _lockdown = null;
        _loading = false;
        _readFailed = true;
      });
      if (notify) {
        final session = _session;
        await showLocalizedOperationNotice(
          context,
          (strings) => strings.vpnStatusReadFailed,
          technicalDetail: (_) => error.toString(),
          isCurrent: () => _eligible && request == _request,
          isCurrentWithPopup: (popup) =>
              mounted &&
              widget.app.foreground &&
              session == _session &&
              AppTaskActivity.isActive(context, ownedPopup: popup) &&
              AppTaskActivity.routeIsActive(_route, ownedPopup: popup),
          eligibilityChanges: Listenable.merge([widget.app, _feedbackChanges]),
          onRetry: () => _load(reportFailure: true),
          identity: ('vpn-status', _session, request),
        );
      }
    }
  }

  Future<void> _open() async {
    if (!_eligible || _opening) return;
    final serial = ++_openSerial;
    final session = _session;
    bool sameSource() =>
        mounted &&
        widget.app.foreground &&
        serial == _openSerial &&
        session == _session;
    bool current() => sameSource() && _eligible;
    setState(() => _opening = true);
    _feedbackChanges.value++;
    try {
      // 打开 Android 的 VPN 设置，不再弹出确认。
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
            widget.app.foreground &&
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
            appBar: AppBar(
              title: Text(strings.alwaysOnTitle),
              actions: [
                IconButton(
                  tooltip: _loading
                      ? strings.vpnStatusLoading
                      : strings.refresh,
                  onPressed: _loading || !_eligible
                      ? null
                      : () => _load(reportFailure: true),
                  color: HomePalette.of(context).syncAction,
                  icon: SizedBox.square(
                    dimension: 24,
                    child: _loading
                        ? Center(
                            child: SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                semanticsLabel: strings.vpnStatusLoading,
                              ),
                            ),
                          )
                        : const Icon(Icons.refresh),
                  ),
                ),
              ],
            ),
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

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../logic/overrides/lan_proxy_settings.dart';
import '../../model/lan_proxy.dart';
import '../../model/override_entry.dart';
import '../components/feedback/operation_feedback.dart';
import '../components/feedback/operation_notice.dart';
import '../app/app_controller.dart';
import '../components/feedback/confirm_action.dart';
import '../navigation/task_activity.dart';

class LanProxyPage extends StatefulWidget {
  const LanProxyPage({super.key, required this.app});
  final AppController app;

  @override
  State<LanProxyPage> createState() => _LanProxyPageState();
}

class _LanProxyPageState extends State<LanProxyPage> {
  final _port = TextEditingController(text: '7890');
  final _raw = TextEditingController();
  final _feedbackOwner = ValueNotifier(false);
  final _noticeChanges = ValueNotifier(0);
  final _portFocus = FocusNode();
  final _portKey = GlobalKey();
  final _selected = <String, String>{};
  OverrideEntry? _saved;
  List<LanInterfaceAddress> _interfaces = const [];
  bool _interfacesLoaded = false;
  Object? _interfaceSource;
  bool _interfaceActive = false;
  bool _readAgain = false;
  bool _readAgainReport = false;
  int _interfaceRequest = 0;
  int _interfaceFailures = 0;
  Timer? _interfaceRetry;
  Timer? _interfaceDeadline;
  Object? _formError;
  bool _portInvalid = false;
  bool _interfaceFailed = false;
  (Object, Object?)? _pendingInterfaceError;
  int? _epoch;
  bool _loaded = false;
  bool _reading = false;
  bool _saving = false;
  bool _udp = true;
  bool _rawMode = false;
  bool _dirty = false;
  ModalRoute<dynamic>? _popup;
  ModalRoute<dynamic>? _detailsRoute;
  bool _readingDetails = false;
  Object? _listenerNoticeSource;
  List<(String, String, String, String, String)> _noticedListeners = const [];

  AppController get app => widget.app;
  bool get _live =>
      mounted &&
      app.interactive &&
      AppTaskActivity.isActive(context, ownedPopup: _popup) &&
      AppTaskActivity.routeIsActive(ModalRoute.of(context), ownedPopup: _popup);
  bool get _canSave =>
      _live && !_saving && app.canEditOverrides && _epoch == app.storageEpoch;
  bool get _detailsActive =>
      _readingDetails &&
      app.interactive &&
      AppTaskActivity.isActive(context, ownedPopup: _detailsRoute) &&
      AppTaskActivity.routeIsActive(
        ModalRoute.of(context),
        ownedPopup: _detailsRoute,
      );

  @override
  void initState() {
    super.initState();
    app.addListener(_changed);
    _readSaved();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncInterfaceRead();
  }

  void _readSaved() {
    if (!app.overridesCurrent || _loaded) return;
    _loaded = true;
    _epoch = app.storageEpoch;
    _saved = app.overrides
        .where((entry) => entry.role == OverrideRole.lanProxy)
        .firstOrNull;
    _raw.text = _saved?.body ?? '{}\n';
    try {
      final settings = LanProxySettings.fromBody(_raw.text);
      _selected.addAll(settings.interfaces);
      _port.text = settings.port.toString();
      _udp = settings.udp;
    } catch (error) {
      _formError = error;
      _rawMode = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && identical(_formError, error)) {
          unawaited(_notice(error, form: true));
        }
      });
    }
  }

  Future<bool> _notice(
    Object error, {
    bool form = false,
    bool port = false,
    String Function(AppLocalizations)? summary,
    Object? identity,
    bool Function()? sourceCurrent,
    Future<void> Function()? onRetry,
  }) {
    final owner = app;
    final epoch = (owner.state.storageEpoch, owner.storageEpoch);
    bool sameSource() =>
        mounted &&
        identical(owner, app) &&
        epoch == (owner.state.storageEpoch, owner.storageEpoch) &&
        (sourceCurrent?.call() ?? true);
    bool withPopup(ModalRoute<dynamic> popup) =>
        sameSource() &&
        app.interactive &&
        AppTaskActivity.isActive(context, ownedPopup: popup) &&
        AppTaskActivity.routeIsActive(
          ModalRoute.of(context),
          ownedPopup: popup,
        );
    String message(AppLocalizations strings) =>
        summary?.call(strings) ??
        (port
            ? strings.lanProxyInvalidPort
            : form
            ? strings.lanProxyFormUnavailable
            : strings.operationFailed);
    String detail(AppLocalizations _) => error.toString();
    Future<void> showDetails() async {
      _readingDetails = true;
      try {
        await showLocalizedOperationMessage(
          context,
          message,
          technicalDetail: detail,
          title: (strings) => strings.errorDetails,
          isCurrent: () => sameSource() && _live,
          isCurrentWithPopup: withPopup,
          eligibilityChanges: Listenable.merge([owner, _noticeChanges]),
          onRoute: (route) => _detailsRoute = route,
          onRetry: onRetry,
        );
      } finally {
        _readingDetails = false;
        _detailsRoute = null;
        if (mounted) _syncInterfaceRead();
      }
    }

    return showLocalizedOperationNotice(
      context,
      message,
      technicalDetail: detail,
      onRetry: onRetry,
      onDetails: showDetails,
      identity: identity,
      eligibilityChanges: Listenable.merge([owner, _noticeChanges]),
      isCurrent: () => sameSource() && _live,
      isCurrentWithPopup: withPopup,
    );
  }

  void _changed() {
    _readSaved();
    if (!mounted) return;
    _syncInterfaceRead();
    setState(() {});
  }

  void _syncInterfaceRead() {
    final source = (
      app.localInterfacesRevision,
      app.localInterfacesError,
      app.state.storageEpoch,
      app.storageEpoch,
    );
    if (_detailsActive) {
      if (_interfaceSource != source) {
        _interfaceSource = source;
        _interfaceRequest++;
        _interfaceRetry?.cancel();
        _interfaceFailures = 0;
        _interfaceFailed = false;
        _pendingInterfaceError = null;
        _readAgain = true;
        _noticeChanges.value++;
      }
      return;
    }
    final active = _live;
    final changed = _interfaceSource != source;
    final entered = active && !_interfaceActive;
    _interfaceSource = source;
    if (!active) {
      if (_interfaceActive) {
        _interfaceRequest++;
        _interfaceRetry?.cancel();
      }
      _interfaceActive = false;
      return;
    }
    _interfaceActive = true;
    if (changed || entered) {
      if (_reading) _interfaceRequest++;
      _interfaceFailures = 0;
      _interfaceFailed = false;
      _pendingInterfaceError = null;
      unawaited(_readInterfaces());
    } else if (_readAgain && !_reading) {
      unawaited(_readInterfaces(reportFailure: _readAgainReport));
    } else {
      final pending = _pendingInterfaceError;
      _pendingInterfaceError = null;
      if (pending != null && _interfaceFailed && pending.$2 == source) {
        _reportInterfaceError(pending.$1, source);
      }
      _scheduleInterfaceRetry();
    }
  }

  void _reportInterfaceError(Object error, Object? source) {
    unawaited(
      _notice(
        error,
        sourceCurrent: () =>
            (_interfaceFailed || _detailsActive) && _interfaceSource == source,
        onRetry: () => _readInterfaces(reportFailure: true),
      ),
    );
  }

  void _scheduleInterfaceRetry() {
    if (!_interfaceFailed ||
        !_live ||
        _reading ||
        _interfaceRetry?.isActive == true) {
      return;
    }
    const backoff = [5, 10, 30, 60];
    final seconds = backoff[(_interfaceFailures - 1).clamp(0, 3)];
    _interfaceRetry = Timer(Duration(seconds: seconds), _readInterfaces);
  }

  Future<void> _readInterfaces({bool reportFailure = false}) async {
    if (!_live) return;
    if (_reading) {
      if (reportFailure) _interfaceRequest++;
      _readAgain = true;
      _readAgainReport |= reportFailure;
      return;
    }
    _interfaceRetry?.cancel();
    _readAgain = _readAgainReport = false;
    final owner = app;
    final source = _interfaceSource;
    final epoch = (owner.state.storageEpoch, owner.storageEpoch);
    final request = ++_interfaceRequest;
    bool current() =>
        mounted &&
        _interfaceActive &&
        (_live || _detailsActive) &&
        identical(owner, app) &&
        request == _interfaceRequest &&
        epoch == (owner.state.storageEpoch, owner.storageEpoch);
    var failed = false;
    void failure(Object error) {
      if (!current()) return;
      final notify = !_interfaceFailed || reportFailure || failed;
      if (!failed) _interfaceFailures++;
      failed = true;
      _interfaceFailed = true;
      if (notify) {
        if (_detailsActive) {
          _pendingInterfaceError = (error, source);
        } else {
          _reportInterfaceError(error, source);
        }
      }
    }

    setState(() => _reading = true);
    _interfaceDeadline = Timer(const Duration(seconds: 5), () {
      failure(
        TimeoutException('Reading local interfaces is still in progress'),
      );
    });
    try {
      final value = await owner.platform.localInterfaces();
      if (!current()) return;
      if (value['error'] case final error?) {
        failure(error);
        return;
      }
      final addresses = (value['addresses'] as List).map((raw) {
        final row = raw as Map;
        return LanInterfaceAddress(
          address: row['address'] as String,
          interfaceName: row['interfaceName'] as String,
          interfaceIndex: row['interfaceIndex'] as int,
          kind: row['kind'] as String,
          available: row['available'] == true,
          platformSelectable: row['selectable'] == true,
          prefixLength: row['prefixLength'] as int?,
        );
      }).toList();
      setState(() {
        _interfaces = List.unmodifiable(addresses);
        _interfacesLoaded = true;
        _interfaceFailed = false;
        _interfaceFailures = 0;
      });
      _noticeChanges.value++;
    } catch (error) {
      failure(error);
    } finally {
      _interfaceDeadline?.cancel();
      _interfaceDeadline = null;
      _reading = false;
      if (mounted) {
        setState(() {});
        if (_readAgain && _live) {
          final report = _readAgainReport;
          unawaited(_readInterfaces(reportFailure: report));
        } else {
          _scheduleInterfaceRetry();
        }
      }
    }
  }

  Future<void> _select(LanInterfaceAddress address, bool value) async {
    if (!_canSave || !address.selectable) return;
    if (value && address.needsConfirmation) {
      final accepted = await confirmAction(
        context,
        title: (strings) => strings.lanProxyAddresses,
        message: (strings) => strings.lanProxyUnknownInterface,
        confirmLabel: (strings) => strings.continueLabel,
        subject: '${address.interfaceName} · ${address.address}',
        onRoute: (route) => _popup = route,
        isCurrent: () => _live,
      );
      if (!accepted || !_canSave) return;
    }
    setState(() {
      _dirty = true;
      if (value) {
        _selected[address.address] = address.interfaceName;
      } else {
        _selected.remove(address.address);
      }
    });
  }

  Future<bool> _submit(Map<String, Object?> command) async {
    if (!_canSave) return false;
    final owner = app;
    final epoch = (owner.state.storageEpoch, owner.storageEpoch);
    bool sameSource() =>
        mounted &&
        identical(owner, app) &&
        epoch == (owner.state.storageEpoch, owner.storageEpoch);
    setState(() => _saving = true);
    _feedbackOwner.value = true;
    try {
      final result = await owner.submitAndWait({
        ...command,
        'id': _saved?.id,
        'revision': _saved?.revision,
        'storageEpoch': _epoch,
        'name': AppLocalizations.of(context).lanProxyTitle,
      }, feedbackOwner: _feedbackOwner);
      if (!mounted || !sameSource()) return false;
      final saved =
          result?.overrideStatus == 'saved' ||
          result?.overrideStatus == 'applied' ||
          result?.overrideStatus == 'applyFailed';
      if (saved) {
        _saved = app.overrides
            .where((entry) => entry.role == OverrideRole.lanProxy)
            .firstOrNull;
        if (command['action'] == 'saveLanProxy') _dirty = false;
      }
      final message =
          result?.resultMessageDescription ?? app.commandErrorMessage;
      if (message != null && _live) {
        final presented = await showAppNotice(
          context,
          message,
          title: result?.resultSuccess == true
              ? (strings) => strings.operationFinished
              : null,
          error: result?.resultSuccess != true,
          eligibilityChanges: owner,
          isCurrent: () => _live && sameSource(),
          isCurrentWithPopup: (popup) =>
              sameSource() &&
              owner.interactive &&
              AppTaskActivity.isActive(context, ownedPopup: popup) &&
              AppTaskActivity.routeIsActive(
                ModalRoute.of(context),
                ownedPopup: popup,
              ),
        );
        if (presented) {
          owner.acknowledgeLocalFeedback(_feedbackOwner, result: result);
        }
      }
      return saved;
    } catch (error) {
      if (mounted && sameSource()) await _notice(error);
      return false;
    } finally {
      _feedbackOwner.value = false;
      if (mounted) setState(() => _saving = false);
    }
  }

  int? _validatedPort() {
    final port = int.tryParse(_port.text);
    if (port != null && port >= 1 && port <= 65535) return port;
    setState(() => _portInvalid = true);
    _portFocus.requestFocus();
    final field = _portKey.currentContext;
    if (field != null) {
      final box = field.findRenderObject();
      final viewport = Scrollable.maybeOf(field)?.context.findRenderObject();
      if (box is RenderBox && viewport is RenderBox) {
        final bounds = box.localToGlobal(Offset.zero) & box.size;
        final visible = viewport.localToGlobal(Offset.zero) & viewport.size;
        if (bounds.top < visible.top || bounds.bottom > visible.bottom) {
          unawaited(Scrollable.ensureVisible(field, alignment: .5));
        }
      }
    }
    unawaited(
      _notice(
        const FormatException('端口必须在 1 到 65535 之间'),
        port: true,
        sourceCurrent: () => _portInvalid,
      ),
    );
    return null;
  }

  InputDecoration _decoration(String label, bool invalid) {
    final theme = Theme.of(context);
    final decoration = theme.inputDecorationTheme;
    final border =
        decoration.enabledBorder ??
        decoration.border ??
        const UnderlineInputBorder();
    final focused = decoration.focusedBorder ?? border;
    return InputDecoration(
      labelText: label,
      enabledBorder: invalid
          ? border.copyWith(
              borderSide: border.borderSide.copyWith(
                color: theme.colorScheme.error,
              ),
            )
          : null,
      focusedBorder: invalid
          ? focused.copyWith(
              borderSide: focused.borderSide.copyWith(
                color: theme.colorScheme.error,
              ),
            )
          : null,
    );
  }

  Future<void> _save() async {
    if (!_canSave) return;
    if (_rawMode) {
      await _submit({
        'action': 'saveLanProxy',
        'body': Uint8List.fromList(utf8.encode(_raw.text)),
      });
      return;
    }
    final port = _validatedPort();
    if (port == null) return;
    await _submit({
      'action': 'saveLanProxy',
      'addresses': _selected.keys.toList(),
      'interfaces': Map<String, String>.from(_selected),
      'port': port,
      'udp': _udp,
    });
  }

  Future<void> _toggle(bool enabled) async {
    if (_dirty || _saved == null) {
      await _save();
      if (_dirty || _saved == null || !_canSave) return;
    }
    await _submit({'action': 'setLanProxyEnabled', 'enabled': enabled});
  }

  List<(String, String, String, String, String)> get _listenerErrors => [
    for (final listener in app.state.lanListeners)
      if (listener['error'] case final String error when error.isNotEmpty)
        (
          listener['name'] as String? ?? '',
          listener['network'] as String? ?? '',
          listener['address'] as String? ?? '',
          listener['state'] as String? ?? '',
          error,
        ),
  ];

  void _scheduleListenerNotice() {
    if (!_live) {
      if (!_detailsActive) _listenerNoticeSource = null;
      return;
    }
    final errors = _listenerErrors;
    if (errors.isEmpty) {
      _listenerNoticeSource = null;
      _noticedListeners = const [];
      return;
    }
    final source = (
      app,
      app.state.storageEpoch,
      app.storageEpoch,
      app.state.generation,
      app.state.core.identity,
    );
    if (_listenerNoticeSource == source &&
        listEquals(_noticedListeners, errors)) {
      return;
    }
    _listenerNoticeSource = source;
    _noticedListeners = errors;
    bool sameSource() =>
        mounted &&
        _listenerNoticeSource == source &&
        source ==
            (
              app,
              app.state.storageEpoch,
              app.storageEpoch,
              app.state.generation,
              app.state.core.identity,
            ) &&
        listEquals(errors, _listenerErrors);
    final detail = errors
        .map(
          (error) => [
            [
              error.$1,
              error.$2,
              error.$3,
              error.$4,
            ].where((value) => value.isNotEmpty).join(' · '),
            error.$5,
          ].join('\n'),
        )
        .join('\n\n');
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!sameSource() || !_live) {
        if (sameSource()) _listenerNoticeSource = null;
        return;
      }
      final presented = await _notice(
        detail,
        summary: (strings) => strings.lanProxyListenerFailed,
        sourceCurrent: sameSource,
        identity: ('lan-listeners', source, Object.hashAll(errors)),
      );
      if (!presented && sameSource()) _listenerNoticeSource = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    _scheduleListenerNotice();
    final strings = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(strings.lanProxyTitle),
        actions: [
          TextButton(
            onPressed: _canSave ? _save : null,
            child: Text(strings.save),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          key: const PageStorageKey('lan-proxy-settings'),
          padding: const EdgeInsets.all(16),
          children: [
            Text(strings.lanProxyNotice),
            SwitchListTile(
              title: Text(strings.lanProxyEnabled),
              value: _saved?.enabled ?? false,
              onChanged: _canSave ? _toggle : null,
            ),
            SwitchListTile(
              title: Text(strings.lanProxyRaw),
              value: _rawMode,
              onChanged: _canSave && _formError == null
                  ? (rawMode) {
                      if (rawMode) {
                        final port = _validatedPort();
                        if (port == null) return;
                        try {
                          _raw.text = LanProxySettings(
                            addresses: _selected.keys,
                            interfaces: _selected,
                            port: port,
                            udp: _udp,
                          ).applyTo(_raw.text);
                        } catch (error) {
                          unawaited(_notice(error));
                          return;
                        }
                      } else {
                        try {
                          final settings = LanProxySettings.fromBody(_raw.text);
                          _selected
                            ..clear()
                            ..addAll(settings.interfaces);
                          _port.text = settings.port.toString();
                          _udp = settings.udp;
                        } catch (error) {
                          setState(() => _formError = error);
                          unawaited(
                            _notice(
                              error,
                              form: true,
                              sourceCurrent: () => identical(_formError, error),
                            ),
                          );
                          return;
                        }
                      }
                      setState(() => _rawMode = rawMode);
                    }
                  : null,
            ),
            if (_rawMode)
              Semantics(
                validationResult: _formError == null
                    ? SemanticsValidationResult.none
                    : SemanticsValidationResult.invalid,
                hint: _formError == null
                    ? null
                    : strings.lanProxyFormUnavailable,
                child: TextField(
                  controller: _raw,
                  minLines: 12,
                  maxLines: null,
                  decoration: _decoration(
                    strings.lanProxyRaw,
                    _formError != null,
                  ),
                  readOnly: !_canSave,
                  onChanged: (_) {
                    setState(() {
                      _dirty = true;
                      _formError = null;
                    });
                    _noticeChanges.value++;
                  },
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              )
            else ...[
              Text(
                strings.lanProxyAddresses,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              if (_interfacesLoaded &&
                  _interfaces.where((address) => address.selectable).isEmpty)
                Text(strings.lanProxyNoAddress),
              for (final address in _interfaces)
                CheckboxListTile(
                  key: ValueKey((
                    'lan-address',
                    address.interfaceName,
                    address.address,
                  )),
                  title: Text(address.address),
                  subtitle: Text('${address.interfaceName} · ${address.kind}'),
                  value: _selected[address.address] == address.interfaceName,
                  onChanged: _canSave && address.selectable
                      ? (value) => _select(address, value == true)
                      : null,
                ),
              for (final selected in _selected.entries)
                if (!_interfacesLoaded ||
                    !_interfaces.any(
                      (item) =>
                          item.address == selected.key &&
                          item.interfaceName == selected.value &&
                          item.selectable,
                    ))
                  CheckboxListTile(
                    title: Text(selected.key),
                    subtitle: _interfacesLoaded
                        ? Text(strings.lanProxyUnavailable)
                        : null,
                    value: true,
                    onChanged: _canSave
                        ? (_) => setState(() {
                            _selected.remove(selected.key);
                            _dirty = true;
                          })
                        : null,
                  ),
              Semantics(
                key: _portKey,
                validationResult: _portInvalid
                    ? SemanticsValidationResult.invalid
                    : SemanticsValidationResult.none,
                hint: _portInvalid ? strings.lanProxyInvalidPort : null,
                child: TextField(
                  controller: _port,
                  focusNode: _portFocus,
                  keyboardType: TextInputType.number,
                  decoration: _decoration(strings.lanProxyPort, _portInvalid),
                  readOnly: !_canSave,
                  onChanged: (_) {
                    setState(() {
                      _dirty = true;
                      _portInvalid = false;
                    });
                    _noticeChanges.value++;
                  },
                ),
              ),
              SwitchListTile(
                title: Text(strings.lanProxyUdp),
                value: _udp,
                onChanged: _canSave
                    ? (value) => setState(() {
                        _udp = value;
                        _dirty = true;
                      })
                    : null,
              ),
              for (final address in _selected.keys)
                ListTile(
                  title: SelectableText(
                    lanEndpoint(address, int.tryParse(_port.text) ?? 7890),
                  ),
                  trailing: IconButton(
                    tooltip: strings.copyOriginalText,
                    icon: const Icon(Icons.copy),
                    onPressed: _live
                        ? () => Clipboard.setData(
                            ClipboardData(
                              text: lanEndpoint(
                                address,
                                int.tryParse(_port.text) ?? 7890,
                              ),
                            ),
                          )
                        : null,
                  ),
                ),
            ],
            const Divider(),
            Text(
              strings.lanProxyActual,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            if (app.state.lanListeners.isEmpty)
              Text(strings.lanProxyNotRunning),
            for (final listener in app.state.lanListeners)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(listener['name'] as String? ?? ''),
                subtitle: SelectableText(
                  [
                    listener['network'] as String? ?? '',
                    listener['address'] as String? ?? '',
                    switch (listener['state']) {
                      'bound' => strings.lanProxySocketBound,
                      'failed' => strings.lanProxySocketFailed,
                      'closed' => strings.lanProxySocketClosed,
                      'closeFailed' => strings.lanProxySocketCloseFailed,
                      final String state => state,
                      _ => '',
                    },
                  ].where((value) => value.isNotEmpty).join(' · '),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    app.removeListener(_changed);
    _interfaceRequest++;
    _interfaceRetry?.cancel();
    _interfaceDeadline?.cancel();
    _port.dispose();
    _raw.dispose();
    _feedbackOwner.dispose();
    _noticeChanges.dispose();
    _portFocus.dispose();
    super.dispose();
  }
}

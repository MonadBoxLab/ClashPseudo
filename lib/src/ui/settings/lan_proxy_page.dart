import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../logic/overrides/lan_proxy_settings.dart';
import '../../model/lan_proxy.dart';
import '../../model/override_entry.dart';
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
  Object? _formError;
  bool _portInvalid = false;
  bool _interfaceFailed = false;
  int? _epoch;
  bool _loaded = false;
  bool _reading = false;
  bool _saving = false;
  bool _udp = true;
  bool _rawMode = false;
  bool _dirty = false;
  ModalRoute<dynamic>? _popup;

  AppController get app => widget.app;
  bool get _live =>
      mounted &&
      app.interactive &&
      AppTaskActivity.isActive(context, ownedPopup: _popup) &&
      AppTaskActivity.routeIsActive(ModalRoute.of(context), ownedPopup: _popup);
  bool get _canSave =>
      _live && !_saving && app.canEditOverrides && _epoch == app.storageEpoch;

  @override
  void initState() {
    super.initState();
    app.addListener(_changed);
    _readSaved();
    unawaited(_readInterfaces());
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
    bool Function()? sourceCurrent,
  }) {
    final owner = app;
    final epoch = (owner.state.storageEpoch, owner.storageEpoch);
    bool sameSource() =>
        mounted &&
        identical(owner, app) &&
        epoch == (owner.state.storageEpoch, owner.storageEpoch) &&
        (sourceCurrent?.call() ?? true);
    return showLocalizedOperationNotice(
      context,
      (strings) => port
          ? strings.lanProxyInvalidPort
          : form
          ? strings.lanProxyFormUnavailable
          : strings.operationFailed,
      technicalDetail: (_) => error.toString(),
      eligibilityChanges: Listenable.merge([owner, _noticeChanges]),
      isCurrent: () => sameSource() && _live,
      isCurrentWithPopup: (popup) =>
          sameSource() &&
          app.interactive &&
          AppTaskActivity.isActive(context, ownedPopup: popup) &&
          AppTaskActivity.routeIsActive(
            ModalRoute.of(context),
            ownedPopup: popup,
          ),
    );
  }

  void _changed() {
    _readSaved();
    if (mounted) setState(() {});
  }

  Future<void> _readInterfaces({bool reportFailure = false}) async {
    if (_reading) return;
    final owner = app;
    final epoch = (owner.state.storageEpoch, owner.storageEpoch);
    bool current() =>
        mounted &&
        identical(owner, app) &&
        epoch == (owner.state.storageEpoch, owner.storageEpoch);
    setState(() => _reading = true);
    try {
      final value = await owner.platform.localInterfaces();
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
      if (!current()) return;
      setState(() => _interfaces = List.unmodifiable(addresses));
      if (value['error'] case final error?) {
        if (!_interfaceFailed || reportFailure) unawaited(_notice(error));
        _interfaceFailed = true;
      } else {
        _interfaceFailed = false;
      }
    } catch (error) {
      if (current()) {
        if (!_interfaceFailed || reportFailure) unawaited(_notice(error));
        _interfaceFailed = true;
      }
    } finally {
      if (mounted) setState(() => _reading = false);
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

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(strings.lanProxyTitle),
        actions: [
          IconButton(
            onPressed: _reading
                ? null
                : () => _readInterfaces(reportFailure: true),
            tooltip: strings.refresh,
            icon: SizedBox.square(
              dimension: 24,
              child: _reading
                  ? const Center(
                      child: SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : const Icon(Icons.refresh),
            ),
          ),
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
              if (_interfaces.where((address) => address.selectable).isEmpty)
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
                if (!_interfaces.any(
                  (item) =>
                      item.address == selected.key &&
                      item.interfaceName == selected.value &&
                      item.selectable,
                ))
                  CheckboxListTile(
                    title: Text(selected.key),
                    subtitle: Text(strings.lanProxyUnavailable),
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
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: SelectableText(
                  const JsonEncoder.withIndent('  ').convert(listener),
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
    _port.dispose();
    _raw.dispose();
    _feedbackOwner.dispose();
    _noticeChanges.dispose();
    _portFocus.dispose();
    super.dispose();
  }
}

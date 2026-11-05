import 'dart:math';

import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';
import '../../../components/input/choice_menu_button.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../../model/messages.dart';
import '../../../../model/config_entry.dart';
import '../shared/fields.dart'
    show
        DefinitionOriginalField,
        DefinitionFieldValidation,
        DefinitionStringListField,
        DefinitionHeadersField;
import '../shared/form_body.dart';
import '../shared/form_interaction.dart';
import '../shared/editor.dart'
    show
        DefinitionEditor,
        captureDefinitionSaveSource,
        definitionEditorLayout,
        definitionSaved,
        definitionToolbarTitle;
import '../shared/save_bar.dart';
import 'proxy_form_type_page.dart';
import '../../../components/feedback/operation_feedback.dart'
    show showAppMessage, showLocalizedOperationMessage;

part 'proxy_form_fields.dart';

/// Await the actual save/apply outcome. Throw on failure, including
/// saved-but-apply-failed, to retain input.
class ProxyFormSaveException implements Exception {
  const ProxyFormSaveException(this.message);
  final AppMessage message;

  @override
  String toString() => 'ProxyFormSaveException';
}

/// Create or edit an original direct definition; the owner retains target ID, revision,
/// epoch and partial-save identity.
class ProxyFormPage extends StatefulWidget {
  const ProxyFormPage({
    super.key,
    this.initialType = 'http',
    this.initialDefinition,
    this.originalValueText,
    this.notice,
    this.onSaveHandled,
    required this.onSave,
  }) : _recordFields = null,
       _recordIdentity = null,
       _recordTitle = null;

  const ProxyFormPage._record({
    required this.initialType,
    required this.initialDefinition,
    this.originalValueText,
    required _RecordFields fields,
    required String identity,
    required String title,
    required this.onSave,
  }) : _recordFields = fields,
       _recordIdentity = identity,
       _recordTitle = title,
       notice = null,
       onSaveHandled = null;

  final _RecordFields? _recordFields;
  final String? _recordIdentity;
  final String? _recordTitle;
  final String initialType;

  /// Complete original local fields or the current parent draft, including untouched
  /// unknown fields.
  final Map<String, Object?>? initialDefinition;

  /// Captured source spans, addressed relative to this definition.
  final String? Function(List<Object> path)? originalValueText;

  /// Context supplied for the current draft, kept mounted during save/retry.
  final Widget? notice;

  /// Invoke once after the mounted form accepts its awaited outcome, then allow local
  /// feedback acknowledgment.
  final VoidCallback? onSaveHandled;
  final Future<void> Function(Map<String, Object?> definition) onSave;

  @override
  State<ProxyFormPage> createState() => _ProxyFormPageState();
}

class _ProxyFormPageState extends State<ProxyFormPage> {
  final _form = GlobalKey<FormState>();
  bool _dirty = false;
  final _scroll = ScrollController();
  final _drafts = <String, Map<String, Object?>>{};
  final _common = <String, Object?>{};
  final _touched = <String>{};
  final _typeFields = <String, Set<String>>{};
  final _recordScrolls = <String, ScrollController>{};
  late ProxyFormType _type;
  late final Map<String, Object?> _initialDefinition;
  Map<String, Object?> _definition = {};
  AppMessage? _failure;
  String? _unknownFailureDetail;
  Object _saveIdentity = Object();
  bool _saving = false;
  ({Object result, bool Function() sourceCurrent})? _completed;
  bool _unsupportedOriginal = false;
  var _unsupportedFieldName = 'type';
  int _rowSequence = 0;

  static const _commonKeys = {
    'name',
    'server',
    'port',
    'username',
    'password',
    'uuid',
    'udp',
    'tfo',
    'mptcp',
    'interface-name',
    'routing-mark',
    'ip-version',
    'dialer-proxy',
  };

  static const _noServer = {
    ProxyFormType.direct,
    ProxyFormType.dns,
    ProxyFormType.reject,
    ProxyFormType.rematch,
    ProxyFormType.zerotier,
    ProxyFormType.easytier,
    ProxyFormType.tailscale,
  };

  AppLocalizations get _strings => AppLocalizations.of(context);
  _Scope get _root => (
    data: _drafts.putIfAbsent(_type.raw, () => <String, Object?>{}),
    path: const <Object>[],
    identity: widget._recordIdentity ?? _type.raw,
    // Raw field identity does not change when only the type selector changes.
    // Keep original values available to the existing touched-field bindings.
    initialPath: const <Object>[],
    active: !_saving,
  );

  @override
  void initState() {
    super.initState();
    _initialDefinition = _copyProxyDraft(widget.initialDefinition ?? const {});
    if (widget._recordFields != null) {
      _type = ProxyFormType.fromRaw(widget.initialType);
      return;
    }
    final type = widget.initialDefinition == null
        ? widget.initialType
        : _initialDefinition['type'];
    final directory = _initialDefinition['state-dir'];
    if (type is! String ||
        !ProxyFormType.values.any((candidate) => candidate.raw == type)) {
      _unsupportedOriginal = true;
      return;
    }
    if (type == 'tailscale' && directory != null && directory is! String) {
      _unsupportedOriginal = true;
      _unsupportedFieldName = 'state-dir';
      return;
    }
    _type = ProxyFormType.fromRaw(type);
    _ensureTailscaleDirectory();
  }

  void _ensureTailscaleDirectory() {
    if (_type != ProxyFormType.tailscale) return;
    final draft = _drafts.putIfAbsent(_type.raw, () => <String, Object?>{});
    draft.putIfAbsent('state-dir', () {
      if (_initialDefinition['type'] == 'tailscale') {
        // Preserve the draft's existing identity directory while correcting required
        // fields.
        return _initialDefinition['state-dir'] as String? ?? '';
      }
      final random = Random.secure();
      final suffix = List.generate(
        4,
        (_) => random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0'),
      ).join();
      return 'tailscale/$suffix';
    });
  }

  void _refreshFields() => setState(() {});

  Future<void> _chooseType() async {
    if (_saving || !DefinitionFormInteraction.canAct(context)) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => ProxyFormTypePage(selectedType: _type.raw),
      ),
    );
    if (!mounted ||
        !DefinitionFormInteraction.canAct(context) ||
        raw == null ||
        raw == _type.raw) {
      return;
    }
    setState(() {
      _dirty = true;
      _type = ProxyFormType.fromRaw(raw);
      _ensureTailscaleDirectory();
    });
  }

  Future<void> _save() async {
    if (!mounted ||
        _saving ||
        _unsupportedOriginal ||
        !DefinitionFormInteraction.canAct(context) ||
        !DefinitionFormBody.validate(_form)) {
      return;
    }
    _definition = _copyProxyDraft(_initialDefinition);
    if (widget._recordFields == null) {
      // A branch choice edits its discriminator, not the fields hidden by it.
      // Only an explicit field interaction may replace or remove original data.
      _definition['type'] = _type.raw;
    }
    _form.currentState!.save();
    final definition = Map<String, Object?>.unmodifiable(_definition);
    final sourceCurrent = captureDefinitionSaveSource(context);
    final ownRoute = ModalRoute.of(context);
    final onSaveHandled = widget.onSaveHandled;
    setState(() {
      _saveIdentity = Object();
      _saving = true;
      _failure = null;
      _unknownFailureDetail = null;
    });
    var saved = false;
    try {
      await widget.onSave(definition);
      saved = true;
    } on ProxyFormSaveException catch (failure) {
      if (mounted &&
          ownRoute?.isActive == true &&
          ownRoute?.animation?.status != AnimationStatus.reverse) {
        setState(() => _failure = failure.message);
      }
    } on ConfigFailure catch (failure) {
      if (mounted &&
          ownRoute?.isActive == true &&
          ownRoute?.animation?.status != AnimationStatus.reverse) {
        setState(() => _failure = failure.message);
      }
    } catch (failure) {
      if (mounted &&
          ownRoute?.isActive == true &&
          ownRoute?.animation?.status != AnimationStatus.reverse) {
        setState(() {
          _unknownFailureDetail = failure.toString();
        });
      }
    } finally {
      if (mounted &&
          !saved &&
          ownRoute?.isActive == true &&
          ownRoute?.animation?.status != AnimationStatus.reverse) {
        setState(() => _saving = false);
      }
    }
    if (!mounted ||
        ownRoute?.isActive != true ||
        ownRoute?.animation?.status == AnimationStatus.reverse) {
      return;
    }
    if (saved) {
      setState(
        () => _completed = (result: definition, sourceCurrent: sourceCurrent),
      );
    }
    if (saved) {
      onSaveHandled?.call();
    } else {
      await _presentFailure(sourceCurrent, onSaveHandled);
    }
    if (mounted && saved && ownRoute?.isActive == true) {
      await definitionSaved(
        context,
        definition,
        isSourceCurrent: sourceCurrent,
      );
    }
  }

  Future<void> _presentFailure(
    bool Function() sourceCurrent,
    VoidCallback? onPresented,
  ) async {
    final identity = _saveIdentity;
    final failure = _failure;
    final detail = _unknownFailureDetail;
    await showDefinitionSaveFailure(
      context,
      failure: failure,
      detail: detail,
      isCurrent: () =>
          mounted &&
          !_saving &&
          _completed == null &&
          sourceCurrent() &&
          identical(_saveIdentity, identity) &&
          identical(_failure, failure) &&
          _unknownFailureDetail == detail,
      onDetails: _showFailure,
      onRetry: _save,
      onPresented: onPresented,
    );
  }

  Future<void> _showFailure() {
    if (!mounted ||
        _saving ||
        _completed != null ||
        !DefinitionFormInteraction.canAct(context)) {
      return Future.value();
    }
    final identity = _saveIdentity;
    final failure = _failure;
    final detail = _unknownFailureDetail;
    bool current() =>
        mounted &&
        !_saving &&
        _completed == null &&
        identical(_saveIdentity, identity) &&
        identical(_failure, failure) &&
        _unknownFailureDetail == detail;
    if (failure != null) {
      return showAppMessage(
        context,
        failure,
        title: (strings) => strings.errorDetails,
        isCurrent: current,
        isCurrentWithPopup: (_) => current(),
        onRetry: _save,
      );
    }
    return showLocalizedOperationMessage(
      context,
      (strings) => strings.proxySaveFailed,
      technicalDetail: (_) => detail,
      title: (strings) => strings.errorDetails,
      isCurrent: current,
      isCurrentWithPopup: (_) => current(),
      onRetry: _save,
    );
  }

  Widget _typeChoice() {
    final strings = _strings;
    return Material(
      child: InkWell(
        key: const ValueKey('proxy-select-type'),
        onTap: _saving ? null : _chooseType,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              Expanded(
                // Keep the label slot stable when choosing another type.
                child: Stack(
                  alignment: AlignmentDirectional.topStart,
                  children: [
                    for (final type in ProxyFormType.values)
                      Visibility(
                        maintainState: true,
                        maintainAnimation: true,
                        maintainSize: true,
                        visible: type == _type,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              strings.proxyFormType,
                              style: Theme.of(context).textTheme.labelMedium,
                            ),
                            Text(
                              type.label,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }

  List<DefinitionFormChapter> _chapters(_Scope root, String title) {
    if (widget._recordFields case final fields?) {
      return [
        DefinitionFormChapter(
          id: 'record',
          title: title,
          children: fields(this, root),
        ),
      ];
    }
    final strings = _strings;
    final protocol = _protocol(root);
    final serverScope = (
      data: root.data,
      path: root.path,
      identity: root.identity,
      initialPath: root.initialPath,
      active: root.active && !_noServer.contains(_type),
    );
    return [
      DefinitionFormChapter(
        id: 'basic',
        title: strings.proxyFormBasic,
        children: [
          _typeChoice(),
          const Divider(height: 1),
          const SizedBox(height: 12),
          _text(root, 'name', required: true),
          DefinitionFormVisibility(
            visible: !_noServer.contains(_type),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _text(
                  serverScope,
                  'server',
                  required: _type != ProxyFormType.wireguard,
                ),
                _number(
                  serverScope,
                  'port',
                  min: 0,
                  max: 65535,
                  required: !{
                    ProxyFormType.wireguard,
                    ProxyFormType.hysteria,
                    ProxyFormType.hysteria2,
                    ProxyFormType.mieru,
                  }.contains(_type),
                ),
              ],
            ),
          ),
        ],
      ),
      DefinitionFormChapter(
        id: 'protocol',
        title: strings.proxyFormProtocol,
        visible: protocol.isNotEmpty,
        secondary: true,
        children: [
          AnimatedSize(
            duration:
                MediaQuery.disableAnimationsOf(context) ||
                    MediaQuery.accessibleNavigationOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 180),
            alignment: AlignmentDirectional.topStart,
            curve: Curves.easeInOutCubic,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: protocol,
            ),
          ),
        ],
      ),
      DefinitionFormChapter(
        id: 'advanced',
        title: strings.proxyFormAdvanced,
        initiallyExpanded: false,
        children: [
          _bool(root, 'tfo', hint: strings.proxyPlatformIgnored),
          _bool(root, 'mptcp'),
          _text(root, 'interface-name', hint: strings.proxyPlatformIgnored),
          _number(root, 'routing-mark', hint: strings.proxyPlatformIgnored),
          _choice(root, 'ip-version', [
            'dual',
            'ipv4',
            'ipv6',
            'ipv4-prefer',
            'ipv6-prefer',
          ]),
          _text(root, 'dialer-proxy'),
          _smux(root),
        ],
      ),
    ];
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: _build);

  Widget _build(BuildContext context, BoxConstraints constraints) {
    final strings = _strings;
    final title =
        widget._recordTitle ??
        (widget.initialDefinition == null
            ? strings.proxyFormTitle
            : strings.editLocalDefinition);
    final layout = definitionEditorLayout(
      context,
      title,
      constraints.biggest,
      footerHeight: _unsupportedOriginal
          ? 0
          : DefinitionSaveBar.heightOf(context) + 1,
    );
    if (_unsupportedOriginal) {
      return Scaffold(
        appBar: AppBar(
          title: definitionToolbarTitle(
            context,
            title,
            compact: layout.compact,
          ),
          toolbarHeight: layout.toolbarHeight,
        ),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            key: const ValueKey('definition-content'),
            constraints: const BoxConstraints(maxWidth: 840),
            child: SingleChildScrollView(
              controller: _scroll,
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.notice != null) widget.notice!,
                  SelectableText(strings.localYamlUnsupportedEdit),
                  const SizedBox(height: 12),
                  SelectableText(_unsupportedFieldName),
                ],
              ),
            ),
          ),
        ),
      );
    }
    final root = _root;
    return DefinitionEditor(
      dirty: _dirty,
      saving: _saving,
      completedResult: _completed?.result,
      isCompletedSourceCurrent: _completed?.sourceCurrent,
      onSave: _save,
      child: Scaffold(
        key: widget._recordIdentity == null
            ? null
            : ValueKey('proxy-record-editor:${widget._recordIdentity}'),
        appBar: AppBar(
          title: definitionToolbarTitle(
            context,
            title,
            compact: layout.compact,
          ),
          toolbarHeight: layout.toolbarHeight,
        ),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            key: const ValueKey('definition-content'),
            constraints: BoxConstraints(
              maxWidth: DefinitionFormBody.widthOf(
                context,
                wide: widget._recordFields == null,
              ),
            ),
            child: Column(
              children: [
                Expanded(
                  child: DefinitionFormBody(
                    scrollKey: const ValueKey('proxy-form-scroll'),
                    form: _form,
                    controller: _scroll,
                    header: widget.notice,
                    onChanged: () {
                      if (!_dirty) setState(() => _dirty = true);
                    },
                    chapters: _chapters(root, title),
                  ),
                ),
                const Divider(height: 1),
                DefinitionSaveBar(
                  id: 'proxy',
                  saveKey: const ValueKey('proxy-save'),
                  saving: _saving,
                  completed: _completed != null,
                  compact: layout.compact,
                  onSave: _save,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _protocol(_Scope s) => switch (_type) {
    ProxyFormType.http => [
      _text(s, 'username'),
      _text(s, 'password', secret: true),
      _bool(s, 'tls'),
      _text(s, 'sni'),
      ..._certificate(s),
      _mapping(s, 'headers'),
    ],
    ProxyFormType.socks5 => [
      _text(s, 'username'),
      _text(s, 'password', secret: true),
      _bool(s, 'tls'),
      _bool(s, 'udp'),
      ..._certificate(s),
    ],
    ProxyFormType.ssh => [
      _text(s, 'username', required: true),
      _text(s, 'password', secret: true),
      _text(s, 'private-key', multiline: true),
      _text(s, 'private-key-passphrase', secret: true),
      _list(s, 'host-key'),
      _list(s, 'host-key-algorithms'),
    ],
    ProxyFormType.masque => [
      _text(s, 'private-key', required: true, secret: true),
      _text(s, 'public-key', required: true),
      ..._texts(s, ['ip', 'ipv6', 'uri', 'sni']),
      _number(s, 'mtu', unit: _strings.proxyUnitBytes),
      _bool(s, 'udp'),
      _number(s, 'handshake-timeout', unit: _strings.proxyUnitSeconds),
      _bool(s, 'skip-cert-verify'),
      _text(s, 'name-cert-verify', hint: _strings.proxyPlatformIgnored),
      _choice(s, 'network', ['h3', 'h2', 'h3-l4proxy']),
      ..._congestion(s),
      _ipStack(s),
      ..._remoteDns(s),
    ],
    ProxyFormType.shadowsocks => _shadowsocks(s),
    ProxyFormType.shadowsocksr => [
      _text(s, 'password', secret: true, required: true),
      _text(s, 'cipher', required: true),
      _text(s, 'obfs', required: true),
      _text(s, 'obfs-param'),
      _text(s, 'protocol', required: true),
      _text(s, 'protocol-param'),
      _bool(s, 'udp'),
    ],
    ProxyFormType.vmess => _vmess(s),
    ProxyFormType.vless => _vless(s),
    ProxyFormType.snell => [
      _text(s, 'psk', required: true, secret: true),
      _bool(s, 'udp'),
      _number(s, 'version'),
      _bool(s, 'reuse'),
      _text(s, 'client-fingerprint'),
      _object(s, 'obfs-opts', (p) => _obfsFields(p, snell: true)),
    ],
    ProxyFormType.trojan => [
      _text(s, 'password', required: true, secret: true),
      _bool(s, 'udp'),
      _text(s, 'sni'),
      _list(s, 'alpn'),
      ..._certificate(s),
      _text(s, 'client-fingerprint'),
      ..._tlsWrappers(s, reality: true),
      _choice(s, 'network', ['tcp', 'ws', 'grpc'], refresh: true),
      ..._transport(s, vless: false, trojan: true),
      _object(
        s,
        'ss-opts',
        (p) => [
          _bool(p, 'enabled'),
          _text(p, 'method'),
          _text(p, 'password', secret: true),
        ],
      ),
    ],
    ProxyFormType.hysteria => [
      _text(s, 'ports'),
      _text(s, 'protocol'),
      _text(s, 'obfs-protocol'),
      _text(s, 'up', required: true),
      _number(s, 'up-speed', unit: _strings.proxyUnitMbps),
      _text(s, 'down', required: true),
      _number(s, 'down-speed', unit: _strings.proxyUnitMbps),
      _text(s, 'auth', secret: true),
      _text(s, 'auth-str', secret: true),
      _text(s, 'obfs', secret: true),
      _text(s, 'sni'),
      _ech(s),
      ..._certificate(s),
      _list(s, 'alpn'),
      ..._numbers(s, [
        'recv-window-conn',
        'recv-window',
      ], unit: _strings.proxyUnitBytes),
      _bool(s, 'disable-mtu-discovery'),
      _bool(s, 'fast-open'),
      _number(s, 'hop-interval', unit: _strings.proxyUnitSeconds),
    ],
    ProxyFormType.hysteria2 => _hysteria2(s),
    ProxyFormType.tuic => [
      _text(s, 'token', secret: true),
      _text(s, 'uuid'),
      _text(s, 'password', secret: true),
      _text(s, 'ip'),
      _number(s, 'heartbeat-interval', unit: _strings.proxyUnitMilliseconds),
      _list(s, 'alpn'),
      _bool(s, 'reduce-rtt'),
      _number(s, 'request-timeout', unit: _strings.proxyUnitMilliseconds),
      _text(s, 'udp-relay-mode'),
      ..._congestion(s),
      _bool(s, 'disable-sni'),
      _number(s, 'max-udp-relay-packet-size', unit: _strings.proxyUnitBytes),
      _bool(s, 'fast-open'),
      _number(s, 'max-open-streams'),
      ..._certificate(s),
      ..._numbers(s, [
        'recv-window-conn',
        'recv-window',
        'max-datagram-frame-size',
      ], unit: _strings.proxyUnitBytes),
      _bool(s, 'disable-mtu-discovery'),
      _text(s, 'sni'),
      _ech(s),
      _bool(s, 'udp-over-stream'),
      _number(s, 'udp-over-stream-version'),
    ],
    ProxyFormType.shadowquic => [
      _text(s, 'username'),
      _text(s, 'password', secret: true),
      _text(s, 'sni'),
      _list(s, 'alpn'),
      _list(s, 'quic-versions'),
      _bool(s, 'udp-over-stream'),
      _bool(s, 'zero-rtt'),
      _number(s, 'keep-alive-interval', unit: _strings.proxyUnitMilliseconds),
      ..._congestion(s),
      _text(s, 'up'),
      _text(s, 'down'),
      ..._numbers(s, [
        'recv-window-conn',
        'recv-window',
        'max-datagram-frame-size',
      ], unit: _strings.proxyUnitBytes),
      _bool(s, 'disable-mtu-discovery'),
      _number(s, 'max-open-streams'),
    ],
    ProxyFormType.gostRelay => [
      ..._bools(s, ['forward', 'udp', 'tls', 'mux']),
      _text(s, 'sni'),
      _text(s, 'username'),
      _text(s, 'password', secret: true),
      ..._certificate(s),
      _text(s, 'client-fingerprint'),
    ],
    ProxyFormType.mieru => [
      _text(s, 'port-range'),
      _choice(s, 'transport', ['TCP', 'UDP'], required: true),
      _bool(s, 'udp'),
      _text(s, 'username', required: true),
      _text(s, 'password', secret: true, required: true),
      ..._texts(s, ['multiplexing', 'handshake-mode', 'traffic-pattern']),
    ],
    ProxyFormType.anytls => [
      _text(s, 'password', secret: true, required: true),
      _list(s, 'alpn'),
      _text(s, 'sni'),
      ..._tlsWrappers(s),
      _text(s, 'client-fingerprint'),
      ..._certificate(s),
      _bool(s, 'udp'),
      _text(s, 'client-metadata'),
      ..._numbers(s, [
        'idle-session-check-interval',
        'idle-session-timeout',
      ], unit: _strings.proxyUnitSeconds),
      _number(s, 'min-idle-session'),
      _bool(s, 'disable-reuse'),
    ],
    ProxyFormType.sudoku => [
      _text(s, 'key', secret: true, required: true),
      _text(s, 'aead-method'),
      _number(s, 'padding-min'),
      _number(s, 'padding-max'),
      _text(s, 'table-type'),
      ..._bools(s, ['enable-pure-downlink', 'http-mask', 'http-mask-tls']),
      _choice(s, 'http-mask-mode', ['legacy', 'stream', 'poll', 'auto', 'ws']),
      ..._texts(s, [
        'http-mask-host',
        'path-root',
        'multiplex',
        'http-mask-multiplex',
      ]),
      _object(
        s,
        'httpmask',
        (p) => [
          _bool(p, 'disable'),
          _choice(p, 'mode', ['legacy', 'stream', 'poll', 'auto', 'ws']),
          _bool(p, 'tls'),
          ..._texts(p, ['host', 'path-root', 'multiplex']),
        ],
      ),
      _text(s, 'custom-table'),
      _list(s, 'custom-tables'),
    ],
    ProxyFormType.trusttunnel => [
      _text(s, 'username'),
      _text(s, 'password', secret: true),
      _list(s, 'alpn'),
      _text(s, 'sni'),
      _ech(s),
      _text(s, 'client-fingerprint'),
      ..._certificate(s),
      ..._bools(s, ['udp', 'health-check', 'quic']),
      ..._congestion(s),
      ..._numbers(s, ['max-connections', 'min-streams', 'max-streams']),
    ],
    ProxyFormType.wireguard => _wireguard(s),
    ProxyFormType.openvpn => [
      ..._texts(s, ['proto', 'dev', 'cipher']),
      _list(s, 'data-ciphers'),
      ..._texts(s, ['data-ciphers-fallback', 'auth', 'comp-lzo']),
      _text(s, 'ca', required: true, multiline: true),
      _text(s, 'cert', multiline: true),
      _text(s, 'key', multiline: true),
      _text(s, 'tls-auth', multiline: true),
      _text(s, 'key-direction'),
      _text(s, 'tls-crypt', multiline: true),
      _text(s, 'tls-crypt-v2', multiline: true),
      _text(s, 'username'),
      _text(s, 'password', secret: true),
      _mapping(s, 'peer-info'),
      ..._numbers(s, [
        'ping',
        'ping-restart',
        'tran-window',
        'handshake-timeout',
      ], unit: _strings.proxyUnitSeconds),
      _number(s, 'mtu', unit: _strings.proxyUnitBytes),
      _bool(s, 'udp'),
      _ipStack(s),
      ..._remoteDns(s),
    ],
    ProxyFormType.zerotier => [
      _text(s, 'network', required: true),
      _text(s, 'state-dir'),
      _text(s, 'identity-secret', secret: true),
      _text(s, 'planet'),
      _number(s, 'mtu', unit: _strings.proxyUnitBytes),
      _ipStack(s),
      _number(s, 'physical-mtu', unit: _strings.proxyUnitBytes),
      _bool(s, 'udp'),
      ..._remoteDns(s),
      ..._bools(s, ['low-bandwidth', 'encrypted-hello']),
      _number(s, 'primary-port', min: 0, max: 65535),
      _number(s, 'secondary-port', min: 0, max: 65535),
      _text(s, 'tcp-fallback-mode'),
      _text(s, 'tcp-fallback-relay'),
      _records(
        s,
        'orbit',
        (owner, p) => [
          owner._text(p, 'world', required: true),
          owner._text(p, 'seed', required: true),
        ],
        validate: (row) =>
            _requiredRecordText(row['world']) ??
            _requiredRecordText(row['seed']),
      ),
      _text(s, 'remote-trace-target'),
      _number(s, 'remote-trace-level', min: 0, max: 30, hint: '0–30'),
    ],
    ProxyFormType.easytier => [
      _text(s, 'network-name'),
      _text(s, 'network-secret', secret: true),
      _text(s, 'hostname'),
      _text(s, 'ipv4'),
      _bool(s, 'dhcp'),
      _list(s, 'peers'),
      _list(s, 'listeners'),
      _bool(s, 'no-listener'),
      _list(s, 'mapped-listeners'),
      _list(s, 'exit-nodes'),
      _list(s, 'proxy-networks'),
      _text(s, 'instance-name'),
      _text(s, 'state-dir'),
      ..._bools(s, [
        'udp',
        'accept-dns',
        'enable-exit-node',
        'enable-encryption',
      ]),
      _text(s, 'encryption-algorithm'),
      ..._bools(s, [
        'private-mode',
        'latency-first',
        'disable-p2p',
        'enable-kcp-proxy',
        'disable-kcp-input',
        'enable-quic-proxy',
        'disable-quic-input',
      ]),
      _number(s, 'mtu', unit: _strings.proxyUnitBytes),
      _text(s, 'tld-dns-zone'),
      _bool(s, 'secure-mode'),
      _text(s, 'local-private-key', secret: true),
      _text(s, 'local-public-key'),
    ],
    ProxyFormType.tailscale => [
      _text(s, 'hostname'),
      _text(s, 'auth-key', secret: true),
      _text(s, 'control-url'),
      _text(s, 'state-dir', required: true),
      ..._bools(s, ['ephemeral', 'udp', 'accept-routes']),
      _text(s, 'exit-node'),
      _bool(s, 'exit-node-allow-lan-access'),
    ],
    ProxyFormType.rematch => [
      _text(s, 'target-rematch-name', nullable: true),
      _text(s, 'target-sub-rule', nullable: true),
    ],
    ProxyFormType.direct || ProxyFormType.dns || ProxyFormType.reject => [],
  };

  List<Widget> _certificate(_Scope s) => [
    _bool(s, 'skip-cert-verify'),
    _text(s, 'name-cert-verify'),
    _text(s, 'fingerprint'),
    _text(s, 'certificate', multiline: true),
    _text(s, 'private-key', multiline: true),
  ];

  List<Widget> _congestion(_Scope s) => [
    _text(s, 'congestion-controller'),
    _number(s, 'cwnd', unit: _strings.proxyUnitPackets),
    _text(s, 'bbr-profile'),
  ];

  List<Widget> _remoteDns(_Scope s) => [
    _bool(s, 'remote-dns-resolve'),
    _list(s, 'dns'),
  ];

  Widget _ipStack(_Scope s) => _object(
    s,
    'ip-stack',
    (p) => [
      _choice(p, 'mode', ['auto', 'mips', 'gvisor']),
      _choice(p, 'congestion-controller', ['cubic', 'reno', 'bbr', 'bbr3']),
    ],
  );

  Widget _ech(_Scope s) => _object(
    s,
    'ech-opts',
    (p) => [
      _bool(p, 'enable'),
      _text(p, 'config'),
      _text(p, 'query-server-name'),
    ],
  );

  List<Widget> _tlsWrappers(_Scope s, {bool reality = false}) => [
    _ech(s),
    _object(
      s,
      'shadow-tls-opts',
      (p) => [_text(p, 'password', secret: true), _number(p, 'version')],
    ),
    _object(
      s,
      'restls-opts',
      (p) => [
        _text(p, 'password', secret: true),
        _text(p, 'version-hint'),
        _text(p, 'restls-script'),
      ],
    ),
    _object(
      s,
      'jls-opts',
      (p) => [_text(p, 'username'), _text(p, 'password', secret: true)],
    ),
    if (reality)
      _object(
        s,
        'reality-opts',
        (p) => [
          _text(p, 'public-key'),
          _text(p, 'short-id'),
          _bool(p, 'support-x25519mlkem768'),
        ],
      ),
  ];

  List<Widget> _vmess(_Scope s) => [
    _text(s, 'uuid', required: true),
    _number(s, 'alterId', required: true),
    _text(s, 'cipher', required: true),
    _bool(s, 'udp'),
    _bool(s, 'tls'),
    _list(s, 'alpn'),
    ..._certificate(s),
    _text(s, 'servername'),
    ..._tlsWrappers(s, reality: true),
    _tlsMirror(s),
    ..._bools(s, [
      'packet-addr',
      'xudp',
      'global-padding',
      'authenticated-length',
    ]),
    _text(s, 'packet-encoding'),
    _text(s, 'client-fingerprint'),
    _choice(s, 'network', [
      'tcp',
      'ws',
      'http',
      'h2',
      'grpc',
      'mkcp',
      'kcp',
      'mekya',
    ], refresh: true),
    ..._transport(s, vless: false),
  ];

  List<Widget> _vless(_Scope s) => [
    _text(s, 'uuid', required: true),
    _text(s, 'flow'),
    _bool(s, 'tls'),
    _list(s, 'alpn'),
    _bool(s, 'udp'),
    _bool(s, 'packet-addr'),
    _bool(s, 'xudp'),
    _text(s, 'packet-encoding'),
    _text(s, 'encryption'),
    ..._tlsWrappers(s, reality: true),
    _mapping(s, 'ws-headers'),
    ..._certificate(s),
    _text(s, 'servername'),
    _text(s, 'client-fingerprint'),
    _choice(s, 'network', [
      'tcp',
      'ws',
      'http',
      'h2',
      'grpc',
      'xhttp',
    ], refresh: true),
    ..._transport(s, vless: true),
  ];

  List<Widget> _transport(
    _Scope s, {
    required bool vless,
    bool trojan = false,
  }) {
    final network = _readString(s, 'network');
    return switch (network) {
      'ws' => [
        _object(
          s,
          'ws-opts',
          (p) => [
            _text(p, 'path'),
            _mapping(p, 'headers'),
            _number(p, 'max-early-data', unit: _strings.proxyUnitBytes),
            _text(p, 'early-data-header-name'),
            _bool(p, 'v2ray-http-upgrade'),
            _bool(p, 'v2ray-http-upgrade-fast-open'),
          ],
          initiallyExpanded: true,
        ),
      ],
      'http' when !trojan => [
        _object(
          s,
          'http-opts',
          (p) => [
            _text(p, 'method'),
            _list(p, 'path'),
            _mapping(p, 'headers', listValues: true),
          ],
          initiallyExpanded: true,
        ),
      ],
      'h2' when !trojan => [
        _object(
          s,
          'h2-opts',
          (p) => [_list(p, 'host'), _text(p, 'path')],
          initiallyExpanded: true,
        ),
      ],
      'grpc' => [_object(s, 'grpc-opts', _grpc, initiallyExpanded: true)],
      'mkcp' || 'kcp' when !vless && !trojan => [
        _object(s, 'mkcp-opts', _mkcp, initiallyExpanded: true),
      ],
      'mekya' when !vless && !trojan => [
        _object(
          s,
          'mekya-opts',
          (p) => [
            _text(p, 'url'),
            _number(p, 'h2-pool-size'),
            _number(p, 'max-write-delay', unit: _strings.proxyUnitMilliseconds),
            _number(p, 'max-request-size', unit: _strings.proxyUnitBytes),
            _number(
              p,
              'polling-interval-initial',
              unit: _strings.proxyUnitMilliseconds,
            ),
            _number(p, 'max-write-size', unit: _strings.proxyUnitBytes),
            _number(
              p,
              'max-write-duration-ms',
              unit: _strings.proxyUnitMilliseconds,
            ),
            _number(p, 'max-simultaneous-write-connection'),
            _number(
              p,
              'packet-writing-buffer',
              unit: _strings.proxyUnitPackets,
            ),
            _object(p, 'kcp', _mkcp),
          ],
          initiallyExpanded: true,
        ),
      ],
      'xhttp' when vless => [
        _object(s, 'xhttp-opts', _xhttp, initiallyExpanded: true),
      ],
      _ => [],
    };
  }

  List<Widget> _grpc(_Scope s) => [
    _text(s, 'grpc-service-name'),
    _text(s, 'grpc-user-agent'),
    _number(s, 'ping-interval', unit: _strings.proxyUnitSeconds),
    ..._numbers(s, ['max-connections', 'min-streams', 'max-streams']),
  ];

  List<Widget> _mkcp(_Scope s) => [
    _number(s, 'mtu', min: 0, max: 4294967295, unit: _strings.proxyUnitBytes),
    _number(
      s,
      'tti',
      min: 0,
      max: 4294967295,
      unit: _strings.proxyUnitMilliseconds,
    ),
    ..._numbers(
      s,
      ['uplink-capacity', 'downlink-capacity'],
      min: 0,
      max: 4294967295,
      unit: 'MiB/s',
    ),
    _bool(s, 'congestion'),
    ..._numbers(
      s,
      ['write-buffer', 'read-buffer'],
      min: 0,
      max: 4294967295,
      unit: _strings.proxyUnitBytes,
    ),
    _text(s, 'seed'),
    _text(s, 'header'),
  ];

  List<Widget> _reuse(_Scope s) => [
    ..._texts(s, [
      'max-concurrency',
      'max-connections',
      'c-max-reuse-times',
      'h-max-request-times',
      'h-max-reusable-secs',
    ]),
    _number(s, 'h-keep-alive-period', unit: _strings.proxyUnitSeconds),
  ];

  List<Widget> _xhttp(_Scope s) => [
    ..._texts(s, ['path', 'host', 'mode']),
    _mapping(s, 'headers'),
    _bool(s, 'no-grpc-header'),
    _text(s, 'x-padding-bytes'),
    _bool(s, 'x-padding-obfs-mode'),
    ..._texts(s, [
      'x-padding-key',
      'x-padding-header',
      'x-padding-placement',
      'x-padding-method',
      'uplink-http-method',
      'session-placement',
      'session-key',
      'session-table',
      'session-length',
      'seq-placement',
      'seq-key',
      'uplink-data-placement',
      'uplink-data-key',
      'uplink-chunk-size',
      'sc-max-each-post-bytes',
      'sc-min-posts-interval-ms',
    ]),
    _object(s, 'reuse-settings', _reuse),
    _object(
      s,
      'download-settings',
      (p) => [
        _text(p, 'path', nullable: true),
        _text(p, 'host', nullable: true),
        _mapping(p, 'headers'),
        _object(p, 'reuse-settings', _reuse),
        _text(p, 'server', nullable: true),
        _number(p, 'port', min: 0, max: 65535),
        _bool(p, 'tls'),
        _list(p, 'alpn'),
        ..._tlsWrappers(p, reality: true),
        _bool(p, 'skip-cert-verify'),
        _text(p, 'name-cert-verify', nullable: true),
        _text(p, 'fingerprint', nullable: true),
        _text(p, 'certificate', nullable: true, multiline: true),
        _text(p, 'private-key', nullable: true, multiline: true),
        _text(p, 'servername', nullable: true),
        _text(p, 'client-fingerprint', nullable: true),
      ],
    ),
  ];

  Widget _tlsMirror(_Scope s) => _object(
    s,
    'tlsmirror-opts',
    (p) => [
      _text(p, 'primary-key', secret: true),
      _list(
        p,
        'explicit-nonce-ciphersuites',
        numeric: true,
        min: 0,
        max: 65535,
      ),
      _object(p, 'defer-instance-derived-write-time', _timeSpec),
      _object(p, 'transport-layer-padding', (t) => [_bool(t, 'enabled')]),
      _object(
        p,
        'connection-enrolment',
        (t) => [
          _text(t, 'primary-ingress-outbound'),
          _text(t, 'primary-egress-outbound'),
        ],
      ),
      _object(
        p,
        'embedded-traffic-generator',
        (t) => [
          _records(
            t,
            'steps',
            (owner, step) => [
              ...owner._texts(step, ['name', 'host', 'path', 'method']),
              owner._records(
                step,
                'headers',
                (editor, header) => [
                  editor._text(header, 'name'),
                  editor._text(header, 'value'),
                  editor._list(header, 'values'),
                ],
              ),
              owner._records(
                step,
                'next-step',
                (editor, candidate) => [
                  editor._number(
                    candidate,
                    'weight',
                    min: -2147483648,
                    max: 2147483647,
                  ),
                  editor._number(candidate, 'goto-location'),
                ],
                validate: owner._nextStepError,
              ),
              ...owner._bools(step, [
                'connection-ready',
                'connection-recall-exit',
                'h2-do-not-wait-for-download-finish',
              ]),
              owner._object(step, 'wait-time', owner._timeSpec),
            ],
            validate: _trafficStepError,
          ),
        ],
      ),
      _bool(p, 'sequence-watermarking-enabled'),
    ],
  );

  List<Widget> _timeSpec(_Scope s) {
    String? validatePair(String key, String value) {
      // Empty inputs remain absent in YAML. Validation uses TimeSpec's zero defaults
      // locally.
      final baseText = key == 'base-nanoseconds'
          ? value
          : _readString(s, 'base-nanoseconds');
      final multiplierText = key == 'uniform-random-multiplier-nanoseconds'
          ? value
          : _readString(s, 'uniform-random-multiplier-nanoseconds');
      return _timeSpecPairError(baseText, multiplierText);
    }

    return [
      _number(
        s,
        'base-nanoseconds',
        min: 0,
        unit: _strings.proxyUnitNanoseconds,
        extraValidate: (value) => validatePair('base-nanoseconds', value),
      ),
      _number(
        s,
        'uniform-random-multiplier-nanoseconds',
        unsigned64: true,
        unit: _strings.proxyUnitNanoseconds,
        hint: 'base-nanoseconds + max(0, uniform-random-multiplier-nanoseconds − 1) ≤ 9223372036854775807',
        extraValidate: (value) =>
            validatePair('uniform-random-multiplier-nanoseconds', value),
      ),
    ];
  }

  List<Widget> _shadowsocks(_Scope s) => [
    _text(s, 'password', secret: true, required: true),
    _text(s, 'cipher', required: true),
    _bool(s, 'udp'),
    _bool(s, 'udp-over-tcp'),
    _number(s, 'udp-over-tcp-version'),
    _text(s, 'client-fingerprint'),
    _choice(s, 'plugin', [
      'obfs',
      'v2ray-plugin',
      'gost-plugin',
      'shadow-tls',
      'restls',
      'jls',
      'kcptun',
    ], refresh: true),
    if ((_readString(s, 'plugin')).isNotEmpty)
      _object(
        s,
        'plugin-opts',
        (p) => _obfsFields(p),
        initiallyExpanded: true,
        draftKey: 'plugin-opts@${_read(s, 'plugin')}',
      ),
  ];

  List<Widget> _obfsFields(_Scope s, {bool snell = false}) {
    final mode = snell ? _readString(s, 'mode') : _readString(_root, 'plugin');
    if (snell) {
      return [
        _choice(s, 'mode', [
          'tls',
          'http',
          'shadow-tls',
          'restls',
          'jls',
        ], refresh: true),
        ..._obfsForMode(s, mode),
      ];
    }
    return _obfsForMode(s, mode);
  }

  List<Widget> _obfsForMode(_Scope s, String mode) => switch (mode) {
    'obfs' => [
      _choice(s, 'mode', ['tls', 'http']),
      _text(s, 'host'),
    ],
    'tls' || 'http' || '' => [_text(s, 'host')],
    'v2ray-plugin' || 'gost-plugin' => [
      _choice(s, 'mode', ['websocket']),
      _text(s, 'host'),
      _text(s, 'path'),
      _bool(s, 'tls'),
      _ech(s),
      _text(s, 'fingerprint'),
      _text(s, 'certificate', multiline: true),
      _text(s, 'private-key', multiline: true),
      _mapping(s, 'headers'),
      _bool(s, 'skip-cert-verify'),
      _text(s, 'name-cert-verify'),
      _bool(s, 'mux'),
      if (mode == 'v2ray-plugin')
        ..._bools(s, ['v2ray-http-upgrade', 'v2ray-http-upgrade-fast-open']),
    ],
    'shadow-tls' => [
      _text(s, 'password', secret: true),
      _text(s, 'host'),
      _text(s, 'fingerprint'),
      _text(s, 'certificate', multiline: true),
      _text(s, 'private-key', multiline: true),
      _bool(s, 'skip-cert-verify'),
      _text(s, 'name-cert-verify'),
      _number(s, 'version'),
      _list(s, 'alpn'),
    ],
    'restls' => [
      _text(s, 'password', secret: true),
      _text(s, 'host'),
      ..._texts(s, ['version-hint', 'restls-script', 'fingerprint']),
      _bool(s, 'skip-cert-verify'),
      _text(s, 'name-cert-verify'),
    ],
    'jls' => [
      _text(s, 'host'),
      _text(s, 'username'),
      _text(s, 'password', secret: true),
      _list(s, 'alpn'),
    ],
    'kcptun' => [
      _text(s, 'key', secret: true),
      _text(s, 'crypt'),
      _text(s, 'mode'),
      ..._numbers(s, [
        'conn',
        'datashard',
        'parityshard',
        'dscp',
        'nodelay',
        'resend',
        'nc',
        'smuxver',
      ]),
      ..._numbers(s, [
        'autoexpire',
        'scavengettl',
        'keepalive',
      ], unit: _strings.proxyUnitSeconds),
      ..._numbers(s, [
        'mtu',
        'sockbuf',
        'smuxbuf',
        'framesize',
        'streambuf',
      ], unit: _strings.proxyUnitBytes),
      _number(s, 'ratelimit', min: 0, max: 4294967295, unit: 'B/s'),
      ..._numbers(s, ['sndwnd', 'rcvwnd'], unit: _strings.proxyUnitPackets),
      _number(s, 'interval', unit: _strings.proxyUnitMilliseconds),
      _bool(s, 'nocomp'),
      _bool(s, 'acknodelay'),
    ],
    _ => [],
  };

  List<Widget> _hysteria2(_Scope s) => [
    _text(s, 'ports'),
    _text(s, 'hop-interval', unit: _strings.proxyUnitSeconds),
    _text(s, 'up'),
    _text(s, 'down'),
    _text(s, 'password', secret: true),
    _choice(s, 'obfs', ['salamander', 'gecko']),
    _text(s, 'obfs-password', secret: true),
    ..._numbers(s, [
      'obfs-min-packet-size',
      'obfs-max-packet-size',
    ], unit: _strings.proxyUnitBytes),
    _text(s, 'sni'),
    _ech(s),
    ..._certificate(s),
    _list(s, 'alpn'),
    _number(s, 'cwnd', unit: _strings.proxyUnitPackets),
    _text(s, 'bbr-profile'),
    _number(s, 'udp-mtu', unit: _strings.proxyUnitBytes),
    _number(s, 'handshake-timeout', unit: _strings.proxyUnitSeconds),
    _object(
      s,
      'realm-opts',
      (p) => [
        _bool(p, 'enable'),
        _text(p, 'server-url'),
        _text(p, 'token', secret: true),
        _text(p, 'realm-id'),
        _list(p, 'stun-servers'),
        _text(p, 'sni'),
        ..._certificate(p),
        _list(p, 'alpn'),
      ],
    ),
    ..._numbers(
      s,
      [
        'initial-stream-receive-window',
        'max-stream-receive-window',
        'initial-connection-receive-window',
        'max-connection-receive-window',
      ],
      min: 0,
      max: 4611686018427387903, // QUIC varint, not the Go uint64 storage range.
      unit: _strings.proxyUnitBytes,
    ),
  ];

  List<Widget> _wireguard(_Scope s) => [
    ..._texts(s, ['ip', 'ipv6']),
    _text(s, 'private-key', secret: true, required: true),
    _number(s, 'workers'),
    _number(s, 'mtu', unit: _strings.proxyUnitBytes),
    _bool(s, 'udp'),
    _number(s, 'persistent-keepalive', unit: _strings.proxyUnitSeconds),
    _ipStack(s),
    ..._wireguardPeer(s, includeServer: false),
    _object(
      s,
      'amnezia-wg-option',
      (p) => [
        _number(p, 'version'),
        _number(p, 'jc', unit: _strings.proxyUnitPackets),
        ..._numbers(p, [
          'jmin',
          'jmax',
          's1',
          's2',
          's3',
          's4',
        ], unit: _strings.proxyUnitBytes),
        ..._texts(p, [
          'h1',
          'h2',
          'h3',
          'h4',
          'i1',
          'i2',
          'i3',
          'i4',
          'i5',
          'j1',
          'j2',
          'j3',
        ]),
        _number(p, 'itime', unit: _strings.proxyUnitSeconds),
        _text(p, 'header-protection-key', secret: true),
        _text(p, 'content-padding-addition', unit: _strings.proxyUnitBytes),
        for (final key in [
          'rekey-after-time',
          'rekey-timeout',
          'reject-after-time',
          'keepalive-timeout',
        ])
          _text(p, key, unit: _strings.proxyUnitSeconds),
        _text(p, 'max-handshake-attempts'),
        _bool(p, 'random-trailers'),
        _bool(p, 'disable-cookies'),
      ],
    ),
    _records(
      s,
      'peers',
      (owner, peer) => owner._wireguardPeer(peer),
      validate: _wireguardPeerError,
    ),
    ..._remoteDns(s),
    _number(s, 'refresh-server-ip-interval', unit: _strings.proxyUnitSeconds),
  ];

  List<Widget> _wireguardPeer(_Scope s, {bool includeServer = true}) => [
    if (includeServer) ...[
      _text(s, 'server'),
      _number(s, 'port', min: 0, max: 65535),
    ],
    _text(s, 'public-key'),
    _text(s, 'pre-shared-key', secret: true),
    _list(s, 'reserved', numeric: true, min: 0, max: 255),
    _list(s, 'allowed-ips'),
  ];

  Widget _smux(_Scope s) => _object(
    s,
    'smux',
    (p) => [
      _bool(p, 'enabled'),
      _choice(p, 'protocol', ['smux', 'yamux', 'h2mux']),
      ..._numbers(p, ['max-connections', 'min-streams', 'max-streams']),
      ..._bools(p, ['padding', 'statistic', 'only-tcp']),
      _object(
        p,
        'brutal-opts',
        (b) => [_bool(b, 'enabled'), _text(b, 'up'), _text(b, 'down')],
      ),
    ],
  );

  @override
  void dispose() {
    _scroll.dispose();
    for (final controller in _recordScrolls.values) {
      controller.dispose();
    }
    super.dispose();
  }
}
